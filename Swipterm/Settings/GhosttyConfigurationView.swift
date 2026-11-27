import SwiftUI

struct GhosttyConfigurationView: View {
    @Bindable var settings: AppSettings
    @State private var lightPickerTheme: String?
    @State private var darkPickerTheme: String?

    var body: some View {
        Form {
            schemeSection(
                "Light Configuration",
                scheme: .light,
                theme: $settings.lightTheme,
                pickerTheme: $lightPickerTheme,
                defaultTheme: AppSettings.defaultLightTheme
            )
            schemeSection(
                "Dark Configuration",
                scheme: .dark,
                theme: $settings.darkTheme,
                pickerTheme: $darkPickerTheme,
                defaultTheme: AppSettings.defaultDarkTheme
            )
            Section("Font Configuration") {
                NavigationLink {
                    FontPickerView(selection: $settings.fontFamily)
                } label: {
                    LabeledContent("Font") {
                        if settings.fontFamily.isEmpty {
                            Text("Follow Theme")
                        } else {
                            Text(settings.fontFamily)
                        }
                    }
                }
                Stepper(value: $settings.fontSize, in: 8 ... 32, step: 1) {
                    LabeledContent("Size") {
                        Text(Int(settings.fontSize), format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Ghostty Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func schemeSection(
        _ header: LocalizedStringKey,
        scheme: ThemePickerView.Scheme,
        theme: Binding<String>,
        pickerTheme: Binding<String?>,
        defaultTheme: String
    ) -> some View {
        let isCustom = theme.wrappedValue.isEmpty
        return Section(header) {
            NavigationLink {
                ThemePickerView(scheme: scheme, selection: theme)
            } label: {
                LabeledContent("Theme", value: isCustom ? pickerTheme.wrappedValue ?? defaultTheme : theme.wrappedValue)
            }
            .disabled(isCustom)
            Toggle("Custom Configuration", isOn: Binding {
                isCustom
            } set: { enabled in
                if enabled {
                    pickerTheme.wrappedValue = theme.wrappedValue
                    theme.wrappedValue = ""
                } else {
                    theme.wrappedValue = pickerTheme.wrappedValue ?? defaultTheme
                }
            })
            if isCustom {
                NavigationLink("Edit Custom Configuration") {
                    EditGhosttyConfigView(scheme: scheme, settings: settings)
                }
            }
        }
    }
}
