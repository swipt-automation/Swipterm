import Foundation
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
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

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
        static let cpuLimit = "cpuLimit"
        static let memoryLimit = "memoryLimit"
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

    var cpuLimit: Int? {
        didSet { store.set(cpuLimit, for: Key.cpuLimit) }
    }

    var memoryLimit: UInt64? {
        didSet { store.set(memoryLimit, for: Key.memoryLimit) }
    }

    var gpuMode: GPUMode {
        didSet { store.set(gpuMode, for: Key.gpuMode) }
    }

    struct EngineConfiguration: Equatable {
        var cpuLimit: Int?
        var memoryLimit: UInt64?
        var gpuMode: GPUMode

        var gpu: LinuxRuntime.GPUConfiguration? {
            switch gpuMode {
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

    var engineConfiguration: EngineConfiguration {
        EngineConfiguration(cpuLimit: cpuLimit, memoryLimit: memoryLimit, gpuMode: gpuMode)
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

    private let store = PreferenceStore.shared

    private init() {
        lightTheme = store.value(String.self, for: Key.lightTheme) ?? Self.defaultLightTheme
        darkTheme = store.value(String.self, for: Key.darkTheme) ?? Self.defaultDarkTheme
        lightConfig = store.value(String.self, for: Key.lightConfig) ?? ""
        darkConfig = store.value(String.self, for: Key.darkConfig) ?? ""
        fontFollowTheme = store.value(Bool.self, for: Key.fontFollowTheme) ?? true
        fontFamily = store.value(String.self, for: Key.fontFamily) ?? ""
        fontSize = store.value(Double.self, for: Key.fontSize) ?? 10
        cpuLimit = store.value(Int?.self, for: Key.cpuLimit) ?? nil
        memoryLimit = store.value(UInt64?.self, for: Key.memoryLimit) ?? nil
        gpuMode = store.value(GPUMode.self, for: Key.gpuMode) ?? .automatic
        isCaffeinateAvailable = store.value(Bool.self, for: Key.caffeinateAvailable) ?? false
        isCaffeinateEnabled = store.value(Bool.self, for: Key.caffeinateEnabled) ?? false
        shortcuts = store.value([TerminalShortcut].self, for: Key.shortcuts) ?? []
    }

    private func saveTerminalAppearance(_ value: some Encodable, for name: String) {
        store.set(value, for: name)
        NotificationCenter.default.post(name: Self.terminalAppearanceDidChange, object: self)
    }
}
