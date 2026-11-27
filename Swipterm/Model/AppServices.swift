import Foundation

final class AppServices {
    let preferences: PreferenceStore
    let settings: AppSettings
    let location: HostLocation
    let clipboard = HostClipboard()
    let pasteStaging = HostPasteStaging()
    let fonts: ImportedFontStore
    let catalog = LinuxDistributionCatalogStore()
    let containers: ContainerStore
    let system: LinuxSystem
    #if DEBUG || SIDELOAD
        let jit: SwiptJIT
    #endif

    init() {
        preferences = PreferenceStore(database: AppDatabase.open())
        settings = AppSettings(store: preferences)
        location = HostLocation(settings: settings)
        fonts = ImportedFontStore(settings: settings)
        containers = ContainerStore(preferences: preferences)
        system = LinuxSystem(
            store: containers,
            settings: settings,
            location: location,
            clipboard: clipboard,
            pasteStaging: pasteStaging,
            catalog: catalog
        )
        #if DEBUG || SIDELOAD
            jit = SwiptJIT(store: preferences)
        #endif
    }
}
