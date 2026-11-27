import ImageIO
import notify
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ScreenshotTests: XCTestCase {
    private struct CapturePlan: Decodable {
        struct Batch: Decodable {
            enum Screen: String, Decodable {
                case setup, terminal
            }

            let screen: Screen
            let attachment: String
            let languages: [String]
        }

        enum Orientation: String, Decodable {
            case portrait, landscapeLeft
        }

        let scenes: [Batch]
        let orientation: Orientation
        let width: Int
        let height: Int
        let innerDisplay: Bool
        let terminalFontSize: Int?
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !SWIPTERM_STORE_SCREENSHOTS || !targetEnvironment(simulator)
            throw XCTSkip("Use make screenshots_ios to build the offline screenshot app for Simulator.")
        #endif
    }

    @MainActor
    func testStoreScreenshots() async throws {
        let json = try XCTUnwrap(ProcessInfo.processInfo.environment["SCREENSHOT_PLAN"], "Use make screenshots_ios to supply the capture plan.")
        let plan = try JSONDecoder().decode(CapturePlan.self, from: Data(json.utf8))
        XCUIDevice.shared.orientation = plan.orientation == .portrait ? .portrait : .landscapeLeft
        for batch in plan.scenes {
            try await capture(batch, plan: plan)
        }
    }

    @MainActor
    private func capture(_ batch: CapturePlan.Batch, plan: CapturePlan) async throws {
        let channel = "io.nekohasekai.swipterm.screenshot." + UUID().uuidString
        var token: Int32 = 0
        XCTAssertEqual(notify_register_check(channel, &token), UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }

        let app = XCUIApplication()
        app.launchArguments = ["--store-screenshot", batch.screen.rawValue, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["SWIPTERM_SCREENSHOT_BATCH"] = channel
        app.launchEnvironment["SWIPTERM_SCREENSHOT_LANGUAGES"] = batch.languages.joined(separator: ",")
        if let size = plan.terminalFontSize {
            app.launchEnvironment["SWIPTERM_SCREENSHOT_FONT_SIZE"] = String(size)
        }
        let started = XCTDarwinNotificationExpectation(notificationName: "\(channel).ready.0")
        app.launch()
        defer { app.terminate() }
        await fulfillment(of: [started], timeout: 20)

        let display = try screenshotDisplay(plan)
        for (offset, language) in batch.languages.enumerated() {
            let index = offset + 1
            let ready = XCTDarwinNotificationExpectation(notificationName: "\(channel).ready.\(index)")
            XCTAssertEqual(notify_set_state(token, UInt64(index)), UInt32(NOTIFY_STATUS_OK))
            XCTAssertEqual(notify_post(channel), UInt32(NOTIFY_STATUS_OK))
            await fulfillment(of: [ready], timeout: 20)

            if offset == 0 {
                let identifier = "store-screenshot-\(batch.screen.rawValue)"
                let landmark = switch batch.screen {
                case .setup: app.textFields[identifier].firstMatch
                case .terminal: app.descendants(matching: .any)[identifier].firstMatch
                }
                XCTAssertTrue(landmark.waitForExistence(timeout: 15), "\(identifier) did not appear")
                if batch.screen == .terminal {
                    try await prepareEnglishKeyboard(in: app)
                }
            }
            try autoreleasepool {
                let image = display.screenshot().image
                let size = image.pixelSize
                let extendEdges = plan.innerDisplay && size.width == plan.width - 1 && size.height == plan.height - 1
                let name = "\(language)__\(batch.attachment)"
                XCTAssertTrue(extendEdges || (size.width == plan.width && size.height == plan.height),
                              "\(name) expected \(plan.width) × \(plan.height), captured \(size.width) × \(size.height)")
                let data = try opaquePNG(image, width: plan.width, height: plan.height, extendEdges: extendEdges)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: UTType.png.identifier)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func prepareEnglishKeyboard(in app: XCUIApplication) async throws {
        // SpringBoard hosts the system keyboard; XCTest can also expose it inside the app.
        let hosts = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        let continueButtons = hosts.map { $0.descendants(matching: .any)["Continue"].firstMatch }
        let letterRows = hosts.map { host in
            ["q", "w", "y"].map { letter in
                host.keys.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", letter, letter)).firstMatch
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var dismissedIntroduction = false
        while clock.now < deadline {
            if let button = continueButtons.first(where: { $0.exists && $0.isHittable }) {
                if !dismissedIntroduction {
                    button.tap()
                    dismissedIntroduction = true
                }
            } else if letterRows.contains(where: { keys in keys.allSatisfy { $0.exists && $0.isHittable } }) {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The English keyboard did not expose hittable Q, W and Y keys (dismissed keyboard introduction: \(dismissedIntroduction))")
    }

    @MainActor
    private func screenshotDisplay(_ plan: CapturePlan) throws -> XCUIScreen {
        guard plan.innerDisplay else { return .main }
        // XCTest designates the outer screen as main even when the inner screen is active.
        return try XCTUnwrap(XCUIScreen.screens.first { display in
            let size = display.screenshot().image.pixelSize
            return (size.width == plan.width && size.height == plan.height)
                || (size.width == plan.width - 1 && size.height == plan.height - 1)
        }, "The iPhone Duo inner display is unavailable in landscape")
    }

    @MainActor
    private func opaquePNG(_ image: UIImage, width: Int, height: Int, extendEdges: Bool) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: image.scale, y: -image.scale)
        UIGraphicsPushContext(context)
        if extendEdges {
            // XCTest omits the left and bottom edge pixels on the Duo inner display.
            let pixel = 1 / image.scale
            image.draw(at: CGPoint(x: 0, y: pixel))
            image.draw(at: CGPoint(x: pixel, y: pixel))
            image.draw(at: .zero)
            image.draw(at: CGPoint(x: pixel, y: 0))
        } else {
            image.draw(at: .zero)
        }
        UIGraphicsPopContext()

        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private extension UIImage {
    var pixelSize: (width: Int, height: Int) {
        (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }
}
