import Cocoa
import FlutterMacOS
import XCTest

@testable import Harbor_SSH

/// Passive responder-chain link. It counts events leaving the real Flutter
/// render view and forwards them unchanged to the original next responder, so
/// installing it cannot alter how the app handles input.
private final class MouseRouteProbe: NSResponder {
  private(set) var mouseDownCount = 0
  private(set) var mouseUpCount = 0

  override func mouseDown(with event: NSEvent) {
    mouseDownCount += 1
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    mouseUpCount += 1
    super.mouseUp(with: event)
  }
}

final class RunnerTests: XCTestCase {
  func testWindowEffectKeepsFlutterClickRouting() throws {
    if Thread.isMainThread {
      try exerciseWindow()
    } else {
      try DispatchQueue.main.sync { try exerciseWindow() }
    }
  }

  private func exerciseWindow() throws {
    let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first)
    let controller = try XCTUnwrap(window.contentViewController as? FlutterViewController)
    let wrapper = controller.view
    let flutterViewClass = try XCTUnwrap(NSClassFromString("FlutterView"))
    let renderView = try XCTUnwrap(wrapper.subviews.first { $0.isKind(of: flutterViewClass) })
    let backdrop = try XCTUnwrap(wrapper.subviews.compactMap { $0 as? NSVisualEffectView }.first)
    let originalFrame = window.frame
    let originalResponder = window.firstResponder
    let originalEnabled = !backdrop.isHidden
    let originalDark = backdrop.appearance?.name == .darkAqua
    let originalNextResponder = renderView.nextResponder
    let probe = MouseRouteProbe()
    probe.nextResponder = originalNextResponder
    renderView.nextResponder = probe
    defer {
      renderView.nextResponder = originalNextResponder
      wrapper.addSubview(backdrop, positioned: .below, relativeTo: nil)
      window.setWindowEffect(enabled: originalEnabled, dark: originalDark)
      window.setFrame(originalFrame, display: true)
      window.makeFirstResponder(originalResponder)
    }
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(renderView))

    func click(_ transition: String) throws {
      window.contentView?.layoutSubtreeIfNeeded()
      let point = NSPoint(x: renderView.bounds.midX, y: renderView.bounds.midY)
      let location = renderView.convert(point, to: nil)
      let downs = probe.mouseDownCount
      let ups = probe.mouseUpCount
      for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01,
          windowNumber: window.windowNumber, context: nil,
          eventNumber: index + 1, clickCount: 1, pressure: index == 0 ? 1 : 0))
        window.sendEvent(event)
      }
      XCTAssertEqual(probe.mouseDownCount, downs + 1, "mouseDown lost after \(transition)")
      XCTAssertEqual(probe.mouseUpCount, ups + 1, "mouseUp lost after \(transition)")
      XCTAssertTrue(window.firstResponder === renderView, "Focus lost after \(transition)")
    }

    window.setWindowEffect(enabled: false, dark: false)
    try click("disabled backdrop")
    window.setWindowEffect(enabled: true, dark: false)
    try click("enabling light backdrop")
    window.setWindowEffect(enabled: true, dark: true)
    try click("switching to dark backdrop")
    var resized = window.frame
    resized.size.width += 160
    resized.size.height += 120
    window.setFrame(resized, display: true)
    try click("resizing with backdrop enabled")

    // A decorative native view must stay non-interactive even if AppKit
    // changes its stacking order during a material update.
    wrapper.addSubview(backdrop, positioned: .above, relativeTo: nil)
    try click("bringing the material above Flutter")
    wrapper.addSubview(backdrop, positioned: .below, relativeTo: nil)

    window.setWindowEffect(enabled: false, dark: false)
    try click("disabling backdrop again")
    window.setWindowEffect(enabled: true, dark: false)
    try click("re-enabling backdrop")
  }
}
