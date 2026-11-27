#if DEBUG || SIDELOAD
    import SwiftUI

    struct JITRow: View {
        @Environment(SwiptJIT.self) private var jit

        @State private var isPresented = false

        var body: some View {
            Button {
                isPresented = true
            } label: {
                LabeledContent {
                    Text(jit.isActive ? "Enabled" : "Not Enabled")
                } label: {
                    Text(verbatim: "JIT")
                }
            }
            .foregroundStyle(.primary)
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    JITView()
                }
            }
        }
    }

    private struct JITView: View {
        @Environment(SwiptJIT.self) private var jit

        @State private var tokenDraft = ""
        @State private var isEditingToken = false

        var body: some View {
            Form {
                Section {
                    Toggle("Enabled", isOn: Binding {
                        jit.isActive || jit.status == .enabling
                    } set: { enabled in
                        jit.setEnabled(enabled)
                    })
                    .disabled(!jit.isConnected && !jit.isPrepared)

                    LabeledContent("Swipt Status") {
                        Text(statusText)
                    }

                    if jit.requiresToken {
                        Button {
                            tokenDraft = jit.token
                            isEditingToken = true
                        } label: {
                            LabeledContent("Swipt Token") {
                                if jit.token.isEmpty {
                                    Text("Required")
                                } else {
                                    Text(verbatim: String(repeating: "•", count: min(jit.token.count, 3)))
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .alert("Swipt Token", isPresented: $isEditingToken) {
                            TextField("Swipt Token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Cancel", role: .cancel) {}
                            Button("OK") {
                                jit.updateToken(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }
                    }
                }
                .alert("Couldn’t Enable JIT", isPresented: Binding {
                    jit.errorMessage != nil
                } set: { presented in
                    if !presented {
                        jit.dismissError()
                    }
                }, presenting: jit.errorMessage) { _ in } message: { message in
                    Text(message)
                }
            }
            .navigationTitle(Text(verbatim: "JIT"))
            .navigationBarTitleDisplayMode(.inline)
        }

        private var statusText: LocalizedStringKey {
            switch jit.status {
            case .searching: "Searching…"
            case .notFound: "Not Found"
            case .connecting: "Connecting…"
            case .unauthenticated: jit.token.isEmpty ? "Token Required" : "Incorrect Token"
            case .connected: "Connected"
            case .enabling: "Enabling…"
            case .unreachable: "Not Connected"
            }
        }
    }
#endif
