import Foundation

final class AppServices {
    let settings: AppSettings
    let location: HostLocation
    let pasteStaging = HostPasteStaging()
    let fonts: ImportedFontStore
    let catalog = LinuxDistributionCatalogStore()
    let containers: ContainerStore
    let powerUsage: PowerUsageStore
    let system: LinuxSystem
    #if DEBUG || SIDELOAD
        let jit: SwiptJIT
    #endif

    init() {
        let database = AppDatabase.open()
        let preferences = PreferenceStore(database: database)
        let clipboard = HostClipboard()
        settings = AppSettings(store: preferences)
        location = HostLocation(settings: settings)
        fonts = ImportedFontStore(settings: settings)
        containers = ContainerStore(preferences: preferences)
        powerUsage = PowerUsageStore(database: database)
        system = LinuxSystem(
            store: containers,
            settings: settings,
            location: location,
            clipboard: clipboard,
            pasteStaging: pasteStaging,
            catalog: catalog,
            powerUsage: powerUsage
        )
        #if DEBUG || SIDELOAD
            jit = SwiptJIT(store: preferences)
        #endif
    }
}
