import SwiftUI
import TrackerBudCore

struct PermissionsFlowView: View {
    @State private var statuses: [PermissionsProbe.Capability: PermissionStatus] = [:]
    @State private var refreshTimer: Timer?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up TrackerBud")
                    .font(.largeTitle).bold()
                Text("Grant the permissions you want. You can skip any or all of them; TrackerBud will run with whichever trackers are enabled.")
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(PermissionsProbe.Capability.allCases) { cap in
                        PermissionCard(capability: cap, status: statuses[cap] ?? .notDetermined)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    UserDefaults.standard.set(true, forKey: "TrackerBud.onboardingComplete")
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .padding()
            }
        }
        .frame(width: 640, height: 620)
        .onAppear { refresh(); startTimer() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            refresh()
        }
    }

    private func refresh() {
        var next: [PermissionsProbe.Capability: PermissionStatus] = [:]
        for cap in PermissionsProbe.Capability.allCases {
            next[cap] = PermissionsProbe.status(for: cap)
        }
        statuses = next
    }
}

struct PermissionCard: View {
    let capability: PermissionsProbe.Capability
    let status: PermissionStatus

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusBadge
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(capability.title)
                    .font(.headline)
                Text(capability.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Text(status.label)
                    .font(.caption)
                    .foregroundColor(status.isGranted ? .green : .secondary)
                Button(status.isGranted ? "Open Settings" : "Grant") {
                    if capability == .screenRecording {
                        PermissionsProbe.requestScreenRecording()
                    }
                    PermissionsProbe.openSystemSettings(for: capability)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.isGranted ? Color.green.opacity(0.6) : Color.gray.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder private var statusBadge: some View {
        Image(systemName: status.isGranted ? "checkmark.circle.fill" : "circle")
            .foregroundColor(status.isGranted ? .green : .gray)
            .font(.system(size: 24))
    }
}
