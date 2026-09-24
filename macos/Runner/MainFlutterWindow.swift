import Cocoa
import FlutterMacOS
import window_manager


class MainFlutterWindow: NSWindow {
  private var localPathsChannel: FlutterMethodChannel?
  private var scopedDirectories: [String: (url: URL, started: Bool)] = [:]
  private var stagedBookmarks: [String: Data] = [:]
  private let bookmarkKey = "harbor.files.default-local-bookmark.v1"
  private let bookmarkPathKey = "harbor.files.default-local-bookmark-path.v1"
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)


    let channel = FlutterMethodChannel(
      name: "harbor/local_paths",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleLocalPathCall(call, result: result)
    }
    localPathsChannel = channel
    super.awakeFromNib()
  }

  deinit {
    stopAllScopedAccess()
  }

  private func handleLocalPathCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickDirectory":
      let panel = NSOpenPanel()
      panel.title = "选择默认本地文件夹"
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      if let arguments = call.arguments as? [String: Any],
         let initial = arguments["initialDirectory"] as? String,
         !initial.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true)
      }
      panel.beginSheetModal(for: self) { [weak self] response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        guard let self else {
          result(FlutterError(code: "window", message: "窗口已关闭", details: nil))
          return
        }
        do {
          try self.stageScopedDirectory(url)
          result(url.standardizedFileURL.path)
        } catch {
          result(FlutterError(
            code: "bookmark",
            message: "无法保存目录访问权限",
            details: nil))
        }
      }
    case "commitDirectory":
      guard let arguments = call.arguments as? [String: Any],
            let requested = arguments["path"] as? String else {
        result(FlutterError(code: "arguments", message: "目录参数无效", details: nil))
        return
      }
      do {
        try commitScopedDirectory(requested)
        result(nil)
      } catch {
        result(FlutterError(
          code: "bookmark",
          message: "无法保存目录访问权限",
          details: nil))
      }
    case "restoreDirectory":
      guard let arguments = call.arguments as? [String: Any],
            let requested = arguments["path"] as? String else {
        result(FlutterError(code: "arguments", message: "目录参数无效", details: nil))
        return
      }
      do {
        result(try restoreScopedDirectory(requested))
      } catch {
        clearScopedDirectory()
        result(nil)
      }
    case "clearDirectory":
      clearScopedDirectory()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stageScopedDirectory(_ url: URL) throws {
    let standardized = url.standardizedFileURL
    stagedBookmarks[standardized.path] = try makeBookmark(standardized)
    retainScopedAccess(standardized)
  }

  private func commitScopedDirectory(_ requested: String) throws {
    let path = URL(fileURLWithPath: requested).standardizedFileURL.path
    if let data = stagedBookmarks.removeValue(forKey: path) {
      UserDefaults.standard.set(data, forKey: bookmarkKey)
      UserDefaults.standard.set(path, forKey: bookmarkPathKey)
    } else if UserDefaults.standard.string(forKey: bookmarkPathKey) != path {
      // App-container paths need no security scope. Do not pair them with an
      // unrelated bookmark selected earlier.
      UserDefaults.standard.removeObject(forKey: bookmarkKey)
      UserDefaults.standard.removeObject(forKey: bookmarkPathKey)
    }
  }

  private func makeBookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
  }

  private func restoreScopedDirectory(_ requested: String) throws -> String? {
    guard let storedPath = UserDefaults.standard.string(forKey: bookmarkPathKey),
          URL(fileURLWithPath: storedPath).standardizedFileURL.path ==
            URL(fileURLWithPath: requested).standardizedFileURL.path,
          let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
      return nil
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale).standardizedFileURL
    retainScopedAccess(url)
    if stale {
      do {
        stagedBookmarks[url.path] = try makeBookmark(url)
      } catch {
        releaseScopedAccess(url)
        throw error
      }
    }
    return url.path
  }

  private func retainScopedAccess(_ url: URL) {
    let standardized = url.standardizedFileURL
    let path = standardized.path
    if scopedDirectories[path] != nil { return }
    scopedDirectories[path] = (
      url: standardized,
      started: standardized.startAccessingSecurityScopedResource())
  }

  private func releaseScopedAccess(_ url: URL) {
    let path = url.standardizedFileURL.path
    guard let scope = scopedDirectories.removeValue(forKey: path) else { return }
    if scope.started { scope.url.stopAccessingSecurityScopedResource() }
  }

  private func stopAllScopedAccess() {
    for scope in scopedDirectories.values where scope.started {
      scope.url.stopAccessingSecurityScopedResource()
    }
    scopedDirectories.removeAll()
    stagedBookmarks.removeAll()
  }

  private func clearScopedDirectory() {
    // Open local tabs keep their scopes until app teardown.
    stagedBookmarks.removeAll()
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    UserDefaults.standard.removeObject(forKey: bookmarkPathKey)
  }

  override func order(
    _ place: NSWindow.OrderingMode,
    relativeTo otherWin: Int
  ) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
