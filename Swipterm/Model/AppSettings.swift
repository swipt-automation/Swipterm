import Foundation
import GhosttyTheme
import Observation
import SwiptermKit

nonisolated enum GPUMode: String, Codable, Hashable, Sendable {
    case automatic
    case moltenVK
    case kosmicKrisp
    case disabled

    init(_ backend: LinuxRuntime.GPUBackend) {
        switch backend {
        case .moltenVK:
            self = .moltenVK
        case .kosmicKrisp:
            self = .kosmicKrisp
        }
    }

    var configuration: LinuxRuntime.GPUConfiguration? {
        switch self {
        case .automatic:
            .automatic
        case .moltenVK:
            .specific(.moltenVK)
        case .kosmicKrisp:
            .specific(.kosmicKrisp)
        case .disabled:
            nil
        }
    }
}

@Observable
final class AppSettings {
    static let terminalAppearanceDidChange = Notification.Name("AppSettings.terminalAppearanceDidChange")
    static let defaultLightTheme = "Alabaster"
    static let defaultDarkTheme = "Afterglow"

    private enum Key {
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let lightConfig = "lightConfig"
        static let darkConfig = "darkConfig"
        static let fontFollowTheme = "fontFollowTheme"
        static let fontFamily = "fontFamily"
        static let fontSize = "fontSize"
        static let gpuMode = "gpuMode"
        static let caffeinateAvailable = "caffeinateAvailable"
        static let caffeinateEnabled = "caffeinateEnabled"
        static let shortcuts = "shortcuts"
    }

    var lightTheme: String {
        didSet { saveTerminalAppearance(lightTheme, for: Key.lightTheme) }
    }

    var darkTheme: String {
        didSet { saveTerminalAppearance(darkTheme, for: Key.darkTheme) }
    }

    var lightConfig: String {
        didSet { saveTerminalAppearance(lightConfig, for: Key.lightConfig) }
    }

    var darkConfig: String {
        didSet { saveTerminalAppearance(darkConfig, for: Key.darkConfig) }
    }

    var fontFollowTheme: Bool {
        didSet { saveTerminalAppearance(fontFollowTheme, for: Key.fontFollowTheme) }
    }

    var fontFamily: String {
        didSet { saveTerminalAppearance(fontFamily, for: Key.fontFamily) }
    }

    var fontSize: Double {
        didSet { saveTerminalAppearance(fontSize, for: Key.fontSize) }
    }

    var gpuMode: GPUMode {
        didSet { store.set(gpuMode, for: Key.gpuMode) }
    }

    var isCaffeinateAvailable: Bool {
        didSet { store.set(isCaffeinateAvailable, for: Key.caffeinateAvailable) }
    }

    var isCaffeinateEnabled: Bool {
        didSet { store.set(isCaffeinateEnabled, for: Key.caffeinateEnabled) }
    }

    var shortcuts: [TerminalShortcut] {
        didSet { store.set(shortcuts, for: Key.shortcuts) }
    }

    private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        lightTheme = Self.storedTheme(in: store, for: Key.lightTheme) ?? Self.defaultLightTheme
        darkTheme = Self.storedTheme(in: store, for: Key.darkTheme) ?? Self.defaultDarkTheme
        lightConfig = store.value(String.self, for: Key.lightConfig) ?? ""
        darkConfig = store.value(String.self, for: Key.darkConfig) ?? ""
        fontFollowTheme = store.value(Bool.self, for: Key.fontFollowTheme) ?? true
        fontFamily = store.value(String.self, for: Key.fontFamily) ?? ""
        fontSize = store.value(Double.self, for: Key.fontSize) ?? 10
        gpuMode = store.value(GPUMode.self, for: Key.gpuMode) ?? .automatic
        isCaffeinateAvailable = store.value(Bool.self, for: Key.caffeinateAvailable) ?? false
        isCaffeinateEnabled = store.value(Bool.self, for: Key.caffeinateEnabled) ?? false
        shortcuts = store.value([TerminalShortcut].self, for: Key.shortcuts) ?? []
    }

    private static func storedTheme(in store: PreferenceStore, for name: String) -> String? {
        guard let theme = store.value(String.self, for: name) else { return nil }
        guard theme.isEmpty || GhosttyThemeCatalog.theme(named: theme) != nil else {
            store.remove(name)
            return nil
        }
        return theme
    }

    private func saveTerminalAppearance(_ value: some Encodable, for name: String) {
        store.set(value, for: name)
        NotificationCenter.default.post(name: Self.terminalAppearanceDidChange, object: self)
    }
}
