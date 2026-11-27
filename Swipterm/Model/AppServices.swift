import Foundation

final class AppServices {
    let settings: AppSettings
    let location: HostLocation
    let pasteStaging = HostPasteStaging()
    let fonts: ImportedFontStore
    let catalog = LinuxDistributionCatalogStore()
    let containers: ContainerStore
    let system: LinuxSystem
    #if DEBUG || SIDELOAD
        let jit: SwiptJIT
    #endif

    init() {
        let preferences = PreferenceStore(database: AppDatabase.open())
        let clipboard = HostClipboard()
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
