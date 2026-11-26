#if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
    import SwiftUI
    import UIKit

    enum StoreScreenshot: String {
        case setup
        case terminal

        static let current: Self = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--store-screenshot") else {
                return .setup
            }
            guard flag + 1 < arguments.count, let screen = Self(rawValue: arguments[flag + 1]) else {
                preconditionFailure("--store-screenshot requires setup or terminal")
            }
            return screen
        }()

        static let alpineRelease = LinuxReleaseImage(
            id: "alpine-3.24-arm64",
            distribution: .alpine,
            releaseKey: "3.24",
            displayTitle: "3.24",
            buildSerial: "",
            artifactPath: "",
            sortRank: 0,
            isRecommended: true
        )

        /// The guest's /etc/motd is displayed in English in every app localization.
        static let loginScreen: String = {
            let hostname = LinuxDistribution.alpine.defaultContainerName
            let motd = """
            Welcome to Alpine!

            The Alpine Wiki contains a large amount of how-to guides and general
            information about administrating Alpine systems.
            See <https://wiki.alpinelinux.org/>.

            You can setup the system with the command: setup-alpine

            You may change this message by editing /etc/motd.
            """
            return "\u{1B}]0;\(hostname)\u{07}" + motd.replacingOccurrences(of: "\n", with: "\r\n")
                + "\r\n\r\n\(hostname):~$ "
        }()
    }

    @Observable
    final class StoreScreenshotLocalization {
        var locale = Locale.current

        var direction: LayoutDirection {
            locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }
    }

    struct StoreScreenshotLocaleModifier: ViewModifier {
        let localization: StoreScreenshotLocalization

        func body(content: Content) -> some View {
            content
                .environment(\.locale, localization.locale)
                .environment(\.layoutDirection, localization.direction)
        }
    }

    struct StoreScreenshotBatch<Content: View>: View {
        private let channel = ProcessInfo.processInfo.environment["SWIPTERM_SCREENSHOT_BATCH"]

        @ViewBuilder let content: () -> Content
        @State private var localization = StoreScreenshotLocalization()
        @State private var request = 0

        var body: some View {
            content()
                .environment(localization)
                .modifier(StoreScreenshotLocaleModifier(localization: localization))
                .preferredColorScheme(.light)
                .transaction { $0.disablesAnimations = true }
                .background {
                    if let channel {
                        let languages = ProcessInfo.processInfo.environment["SWIPTERM_SCREENSHOT_LANGUAGES"]!
                            .split(separator: ",").map { Locale(identifier: String($0)) }
                        StoreScreenshotControl(name: channel, index: request, direction: localization.direction) { index in
                            precondition(index > request && index <= languages.count, "Unexpected screenshot request \(index)")
                            localization.locale = languages[index - 1]
                            request = index
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
        }
    }
#endif
