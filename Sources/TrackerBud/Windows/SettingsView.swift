import SwiftUI
import TrackerBudCore

struct SettingsView: View {
    @EnvironmentObject var coordinator: TrackingCoordinator
    @State private var rules: [EventStore.PrivacyRule] = []
    @State private var newBundleID: String = ""
    @State private var newAction: String = "skip-screenshot"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2).bold()
                .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Section {
                        ForEach(coordinator.trackerStatus.sorted(by: { $0.key < $1.key }), id: \.key) { key, running in
                            HStack {
                                Circle().fill(running ? Color.green : Color.gray).frame(width: 8, height: 8)
                                Text(key.capitalized + " tracker")
                                Spacer()
                                Text(running ? "running" : (coordinator.isPaused ? "paused" : "off"))
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    } header: {
                        Text("Trackers")
                            .font(.headline)
                    }

                    Section {
                        Toggle("Pause all tracking", isOn: $coordinator.isPaused)
                            .toggleStyle(.switch)
                    } header: {
                        Text("Master")
                            .font(.headline)
                    }

                    Section {
                        if rules.isEmpty {
                            Text("No exclusion rules.")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(rules) { rule in
                                HStack {
                                    Text(rule.bundleID ?? rule.urlPattern ?? "—")
                                        .font(.callout.monospaced())
                                    Spacer()
                                    Text(rule.action)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button {
                                        removeRule(rule.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        HStack {
                            TextField("Bundle ID (e.g. com.example.app)", text: $newBundleID)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $newAction) {
                                Text("skip screenshot").tag("skip-screenshot")
                                Text("skip clipboard").tag("skip-clipboard")
                                Text("skip all").tag("skip-all")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                            Button("Add", action: addRule)
                                .disabled(newBundleID.isEmpty)
                        }
                    } header: {
                        Text("Privacy exclusions")
                            .font(.headline)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Database: ~/Library/Application Support/TrackerBud/trackerbud.db")
                                .font(.caption.monospaced())
                            Text("Sensitive columns (window titles, clipboard text, URLs, file paths, OCR) are AES-GCM encrypted per-field with a key in Keychain. Full DB encryption via SQLCipher is deferred (see README).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Storage")
                            .font(.headline)
                    }
                }
                .padding()
            }
        }
        .onAppear(perform: loadRules)
    }

    private func loadRules() {
        rules = (try? EventStore.shared.privacyRules()) ?? []
    }

    private func addRule() {
        try? EventStore.shared.addPrivacyRule(bundleID: newBundleID, urlPattern: nil, action: newAction)
        newBundleID = ""
        loadRules()
    }

    private func removeRule(_ id: Int64) {
        try? EventStore.shared.removePrivacyRule(id: id)
        loadRules()
    }
}
