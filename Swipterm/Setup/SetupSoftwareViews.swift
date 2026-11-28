import SwiftUI

struct SetupSSH: Equatable {
    var isEnabled = false
    var port = String(SSHServer.defaultPort)
    var authentication = SSHAuthentication.password
    var authorizedKeys = ""

    var validPort: Int? {
        Int(port).flatMap { SSHServer.ports.contains($0) ? $0 : nil }
    }
}

struct SetupSSHView: View {
    @Binding var ssh: SetupSSH

    @State private var isEditingPublicKey = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $ssh.isEnabled) {
                    Text(verbatim: "SSH")
                }
                if ssh.isEnabled {
                    LabeledContent("Port") {
                        TextField("Port", text: $ssh.port, prompt: Text(verbatim: String(SSHServer.defaultPort)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
            }

            if ssh.isEnabled {
                Section("Authentication") {
                    Picker("Method", selection: $ssh.authentication) {
                        Text("Password")
                            .tag(SSHAuthentication.password)
                        Text("Public Key")
                            .tag(SSHAuthentication.publicKey)
                        Text("Password & Public Key")
                            .tag(SSHAuthentication.passwordAndPublicKey)
                    }
                    if ssh.authentication.allowsPublicKey {
                        Button {
                            isEditingPublicKey = true
                        } label: {
                            LabeledContent("Public Key") {
                                if ssh.authorizedKeys.isEmpty {
                                    Text("Not Configured")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Configured")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(FormColumnModifier())
        .navigationTitle(Text(verbatim: "SSH"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingPublicKey) {
            PublicKeySheet(authorizedKeys: $ssh.authorizedKeys)
        }
    }
}

private struct PublicKeySheet: View {
    @Binding var authorizedKeys: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(authorizedKeys: Binding<String>) {
        _authorizedKeys = authorizedKeys
        _text = State(initialValue: authorizedKeys.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CodeEditor(text: $text, textStyle: .body)
                        .frame(minHeight: 180)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(verbatim: "ssh-ed25519 AAAA…")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if !authorizedKeys.isEmpty {
                    Section {
                        Button("Delete", role: .destructive) {
                            authorizedKeys = ""
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        authorizedKeys = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SetupSoftwareView: View {
    @Binding var software: ContainerSoftware
    @Binding var ssh: SetupSSH
    let shells: [LoginShell]

    var body: some View {
        Form {
            Section {
                if !shells.isEmpty {
                    Picker("Shell", selection: $software.shell) {
                        ForEach(shells) { shell in
                            Text(verbatim: shell.displayName)
                                .tag(Optional(shell))
                        }
                    }
                }
                NavigationLink {
                    SetupSSHView(ssh: $ssh)
                } label: {
                    LabeledContent {
                        if ssh.isEnabled {
                            Text(verbatim: ssh.port)
                        } else {
                            Text("Off")
                        }
                    } label: {
                        Text(verbatim: "SSH")
                    }
                }
            }

            Section("Developer Tools") {
                ForEach(DeveloperTool.allCases, id: \.self) { tool in
                    let isSelected = software.developerTools.contains(tool)
                    SetupSelectionRow(title: Text(tool.displayName), isSelected: isSelected) {
                        software.setDeveloperTool(tool, isEnabled: !isSelected)
                    }
                }
            }

            #if DEBUG || SIDELOAD || TESTFLIGHT
                Section("Coding Agents") {
                    ForEach(CodingAgent.allCases, id: \.self) { agent in
                        let isSelected = software.agents.contains(agent)
                        SetupSelectionRow(title: Text(agent.displayName), isSelected: isSelected) {
                            software.setAgent(agent, isEnabled: !isSelected)
                        }
                    }
                }
            #endif
        }
        .modifier(FormColumnModifier())
        .navigationTitle("Software")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetupSelectionRow: View {
    let title: Text
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                title
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
