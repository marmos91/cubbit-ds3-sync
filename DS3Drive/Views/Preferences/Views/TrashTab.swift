import DS3Lib
import SwiftUI

struct TrashTab: View {
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    @State private var trashEnabled: Bool = true
    @State private var retentionDays: Int = DefaultSettings.Trash.defaultRetentionDays
    @State private var showEmptyConfirmation: Bool = false

    private let retentionOptions: [(label: String, days: Int)] = [
        ("7 days", 7),
        ("14 days", 14),
        ("30 days", 30),
        ("60 days", 60),
        ("90 days", 90),
        ("Never", 0)
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $trashEnabled) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Enable trash")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Deleted files are moved to a .trash/ folder in S3 instead of being permanently removed.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
                .onChange(of: trashEnabled) { _, newValue in
                    saveSettings(enabled: newValue, retentionDays: retentionDays)
                }
            } header: {
                Text("Trash")
                    .font(DS3Typography.caption)
            }

            Section {
                Picker("Auto-empty trash after", selection: $retentionDays) {
                    ForEach(retentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .disabled(!trashEnabled)
                .onChange(of: retentionDays) { _, newValue in
                    saveSettings(enabled: trashEnabled, retentionDays: newValue)
                }
            } header: {
                Text("Retention")
                    .font(DS3Typography.caption)
            }

            Section {
                Button(role: .destructive) {
                    showEmptyConfirmation = true
                } label: {
                    Label("Empty All Trash Now", systemImage: "trash")
                }
                .disabled(!trashEnabled)
                .confirmationDialog(
                    "Empty all trash?",
                    isPresented: $showEmptyConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Empty Trash", role: .destructive) {
                        emptyAllTrash()
                    }
                } message: {
                    Text(
                        "This will permanently delete all trashed items across all drives. This action cannot be undone."
                    )
                }
            } header: {
                Text("Actions")
                    .font(DS3Typography.caption)
            }
        }
        .formStyle(.grouped)
        .padding(DS3Spacing.lg)
        .onAppear {
            loadSettings()
        }
    }

    private func loadSettings() {
        guard let firstDrive = ds3DriveManager.drives.first else { return }
        let settings = (try? SharedData.default().loadTrashSettings(forDrive: firstDrive.id)) ?? TrashSettings()
        trashEnabled = settings.enabled
        retentionDays = settings.retentionDays
    }

    private func saveSettings(enabled: Bool, retentionDays: Int) {
        let settings = TrashSettings(enabled: enabled, retentionDays: retentionDays)
        for drive in ds3DriveManager.drives {
            try? SharedData.default().saveTrashSettings(forDrive: drive.id, settings: settings)
        }
    }

    private func emptyAllTrash() {
        for drive in ds3DriveManager.drives {
            try? SharedData.default().setEmptyTrashRequest(forDrive: drive.id, requested: true)
        }
    }
}

#Preview {
    TrashTab()
        .environment(DS3DriveManager(appStatusManager: AppStatusManager.default()))
        .frame(width: 500, height: 380)
}
