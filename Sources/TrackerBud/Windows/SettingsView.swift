import SwiftUI
import TrackerBudCore
import Analysis

struct SettingsView: View {
    @EnvironmentObject var coordinator: TrackingCoordinator
    @State private var rules: [EventStore.PrivacyRule] = []
    @State private var newBundleID: String = ""
    @State private var newAction: String = "skip-screenshot"
    @State private var digestSettings = DigestScheduler.loadSettings()
    @State private var apiKeyInput: String = ""
    @State private var apiKeyPresent: Bool = false
    @State private var todaySpend: (input: Int, output: Int, cost: Double) = (0, 0, 0)

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
                        Toggle("Enable daily digest", isOn: Binding(
                            get: { digestSettings.dailyEnabled },
                            set: { digestSettings.dailyEnabled = $0; persistDigestSettings() }
                        ))
                        HStack {
                            Text("Daily digest hour:")
                            Picker("", selection: Binding(
                                get: { digestSettings.dailyHour },
                                set: { digestSettings.dailyHour = $0; persistDigestSettings() }
                            )) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }
                        Toggle("Enable weekly digest (every Sunday)", isOn: Binding(
                            get: { digestSettings.weeklyEnabled },
                            set: { digestSettings.weeklyEnabled = $0; persistDigestSettings() }
                        ))
                        Toggle("Send macOS notifications", isOn: Binding(
                            get: { digestSettings.notificationsEnabled },
                            set: { digestSettings.notificationsEnabled = $0; persistDigestSettings() }
                        ))
                        Toggle("Write markdown to ~/Documents/TrackerBud-Digests", isOn: Binding(
                            get: { digestSettings.markdownExportEnabled },
                            set: { digestSettings.markdownExportEnabled = $0; persistDigestSettings() }
                        ))
                        HStack {
                            Button("Generate today's digest now") {
                                Task { await DigestScheduler.shared.runNow(kind: .daily) }
                            }
                            Button("Generate weekly digest now") {
                                Task { await DigestScheduler.shared.runNow(kind: .weekly) }
                            }
                        }
                    } header: {
                        Text("Insights delivery")
                            .font(.headline)
                    }

                    Section {
                        if apiKeyPresent {
                            HStack {
                                Text("Claude API key set")
                                    .foregroundColor(.green)
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Spacer()
                                Button("Clear") { clearAPIKey() }
                            }
                        } else {
                            HStack {
                                SecureField("Paste your Claude API key (sk-ant-...)", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") { saveAPIKey() }
                                    .disabled(apiKeyInput.isEmpty)
                            }
                            Text("Stored in Keychain. Used only when you trigger an LLM-powered summary or query.")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today's API spend")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                Text("\(todaySpend.input) in / \(todaySpend.output) out tokens")
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text(String(format: "$%.4f", todaySpend.cost))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    } header: {
                        Text("Claude API")
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
        .onAppear { loadRules(); refreshAPIState() }
    }

    private func persistDigestSettings() {
        DigestScheduler.saveSettings(digestSettings)
    }

    private func refreshAPIState() {
        apiKeyPresent = APIKeyVault.shared.hasKey()
        todaySpend = (try? EventStore.shared.todayAPISpend()).map { ($0.inputTokens, $0.outputTokens, $0.costUSD) } ?? (0, 0, 0)
    }

    private func saveAPIKey() {
        try? APIKeyVault.shared.set(key: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
        apiKeyInput = ""
        refreshAPIState()
    }

    private func clearAPIKey() {
        try? APIKeyVault.shared.clear()
        refreshAPIState()
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
