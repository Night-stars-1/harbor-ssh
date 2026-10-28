import Cocoa
import Darwin
import FlutterMacOS
import window_manager


/// Clicks that reach the backdrop belong to Flutter, never to a window drag.
/// The title bar drag area calls startDragging explicitly.
private final class WindowBackdropView: NSVisualEffectView {
  override var mouseDownCanMoveWindow: Bool { false }
}

class MainFlutterWindow: NSWindow {
  private var localPathsChannel: FlutterMethodChannel?
  private var windowEffectChannel: FlutterMethodChannel?
  private var systemFontsChannel: FlutterMethodChannel?
  private weak var flutterViewController: FlutterViewController?
  private let backdrop = WindowBackdropView()
  private var scopedDirectories: [String: (url: URL, started: Bool)] = [:]
  private var stagedBookmarks: [String: Data] = [:]
  private let bookmarkKey = "harbor.files.default-local-bookmark.v1"
  private let bookmarkPathKey = "harbor.files.default-local-bookmark-path.v1"
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    // The acrylic backdrop sits under the Flutter view. Plugins look the
    // Flutter controller up among the content controller's children.
    let container = NSViewController()
    container.view = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
    backdrop.frame = container.view.bounds
    backdrop.autoresizingMask = [.width, .height]
    backdrop.blendingMode = .behindWindow
    backdrop.material = .underWindowBackground
    backdrop.state = .followsWindowActiveState
    backdrop.isHidden = true
    container.view.addSubview(backdrop)
    container.addChild(flutterViewController)
    flutterViewController.view.frame = container.view.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    container.view.addSubview(flutterViewController.view)
    // Once the backdrop is visible AppKit delivers mouse events to it rather
    // than to the transparent Flutter view above, so let them bubble to the
    // Flutter controller instead of the container.
    backdrop.nextResponder = flutterViewController
    self.flutterViewController = flutterViewController
    self.contentViewController = container
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)


    let channel = FlutterMethodChannel(
      name: "harbor/local_paths",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleLocalPathCall(call, result: result)
    }
    localPathsChannel = channel
    let effectChannel = FlutterMethodChannel(
      name: "harbor/window_effect",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    effectChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleWindowEffectCall(call, result: result)
    }
    windowEffectChannel = effectChannel
    let fontsChannel = FlutterMethodChannel(
      name: "harbor/system_fonts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fontsChannel.setMethodCallHandler { call, result in
      guard call.method == "monospaceFamilies" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // The fixed-pitch mask lists PostScript face names; Flutter resolves
      // fonts by family.
      let manager = NSFontManager.shared
      let families = Set(
        (manager.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap {
          NSFont(name: $0, size: 12)?.familyName
        })
      result(Array(families))
    }
    systemFontsChannel = fontsChannel
    super.awakeFromNib()
  }

  deinit {
    stopAllScopedAccess()
  }

  private func handleWindowEffectCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "supported":
      result(true)
    case "setAcrylic":
      guard let arguments = call.arguments as? [String: Any],
            let enabled = arguments["enabled"] as? Bool,
            let dark = arguments["dark"] as? Bool else {
        result(FlutterError(
          code: "arguments", message: "Invalid window effect arguments", details: nil))
        return
      }
      backdrop.isHidden = !enabled
      // The tint follows the app theme, not the system appearance.
      backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      // The Flutter view is black behind transparent pixels unless cleared.
      flutterViewController?.backgroundColor = enabled ? .clear : nil
      result(enabled)
    default:
      result(FlutterMethodNotImplemented)
    }
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
    case "createDirectoryExclusive":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "arguments", message: "目录参数无效", details: nil))
        return
      }
      if Darwin.mkdir(path, mode_t(0o755)) == 0 {
        result(nil)
      } else {
        result(FlutterError(
          code: "mkdir",
          message: String(cString: strerror(errno)),
          details: errno))
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
