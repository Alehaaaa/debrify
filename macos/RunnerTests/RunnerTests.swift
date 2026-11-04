import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  @MainActor
  func testFlutterRenderingGeometryUsesTheWindowBackingScale() throws {
    let window = try XCTUnwrap(NSApp.windows.first { $0.contentViewController is FlutterViewController })
    let controller = try XCTUnwrap(window.contentViewController as? FlutterViewController)
    let wrapper = controller.view
    let flutterView = try XCTUnwrap(wrapper.subviews.first)

    // FlutterViewController installs a wrapper around the layer-backed
    // FlutterView. The root must track the window in points, while the
    // actual Flutter surface must track the same rectangle in backing pixels.
    XCTAssertTrue(window.contentView === wrapper)
    XCTAssertFalse(wrapper.wantsLayer, "Flutter's wrapper must not acquire an extra layer")
    XCTAssertTrue(flutterView.wantsLayer, "Flutter must own the renderer layer")
    XCTAssertGreaterThan(wrapper.bounds.width, 0)
    XCTAssertGreaterThan(wrapper.bounds.height, 0)

    func checkGeometry(file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertEqual(flutterView.frame.width, wrapper.bounds.width, accuracy: 1, file: file, line: line)
      XCTAssertEqual(flutterView.frame.height, wrapper.bounds.height, accuracy: 1, file: file, line: line)
      let backing = flutterView.convertToBacking(flutterView.bounds)
      XCTAssertEqual(backing.width, flutterView.bounds.width * window.backingScaleFactor,
                     accuracy: 1, file: file, line: line)
      XCTAssertEqual(backing.height, flutterView.bounds.height * window.backingScaleFactor,
                     accuracy: 1, file: file, line: line)
      if let layer = flutterView.layer {
        XCTAssertEqual(layer.contentsScale, window.backingScaleFactor,
                       accuracy: 0.01, file: file, line: line)
      } else {
        XCTFail("Flutter renderer must own a layer", file: file, line: line)
      }
    }

    checkGeometry()
    let originalFrame = window.frame
    defer { window.setFrame(originalFrame, display: true) }
    window.setContentSize(NSSize(width: wrapper.bounds.width + 80,
                                 height: wrapper.bounds.height + 40))
    window.displayIfNeeded()
    checkGeometry()
  }

}
