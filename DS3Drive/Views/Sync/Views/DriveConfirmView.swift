import SwiftUI
import DS3Lib

struct DriveConfirmView: View {
    var syncAnchor: SyncAnchor
    @State var driveName: String

    var onBack: (() -> Void)?
    var onComplete: ((DS3Drive) -> Void)?

    @State private var nameError: String?

    init(syncAnchor: SyncAnchor, suggestedName: String) {
        self.syncAnchor = syncAnchor
        self._driveName = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: DS3Spacing.lg) {
                // Header
                Text("Confirm your drive")
                    .font(DS3Typography.title)
                    .foregroundStyle(DS3Colors.primaryText)

                // Read-only summary of selection
                summarySection

                // Drive name input
                nameSection
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, DS3Spacing.xxl)

            Spacer()

            // Footer
            footerBar
        }
        .background(DS3Colors.background)
    }

    // MARK: - Summary section

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: DS3Spacing.sm) {
            Text("Selected path")
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.secondaryText)

            HStack(spacing: DS3Spacing.sm) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.orange)
                Text(syncAnchor.project.name)
                    .font(DS3Typography.body)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(DS3Colors.secondaryText)

                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(Color.accentColor)
                Text(syncAnchor.bucket.name)
                    .font(DS3Typography.body)

                if let prefix = syncAnchor.prefix, !prefix.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(DS3Colors.secondaryText)

                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(displayPrefix(prefix))
                        .font(DS3Typography.body)
                }
            }
            .padding(DS3Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DS3Colors.secondaryBackground)
            )
        }
    }

    // MARK: - Name section

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DS3Spacing.sm) {
            Text("Drive name")
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.secondaryText)

            TextField("Enter drive name", text: $driveName)
                .textFieldStyle(.roundedBorder)
                .font(DS3Typography.body)
                .onChange(of: driveName) {
                    validateName()
                }

            if let nameError = nameError {
                Text(nameError)
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.statusError)
            }

            Text("This name will appear in Finder's sidebar when multiple drives are configured.")
                .font(DS3Typography.footnote)
                .foregroundStyle(DS3Colors.secondaryText)
        }
    }

    // MARK: - Footer bar

    @ViewBuilder
    private var footerBar: some View {
        HStack {
            Button {
                onBack?()
            } label: {
                HStack(spacing: DS3Spacing.xs) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, DS3Spacing.lg)

            Spacer()

            Button("Create Drive") {
                createDrive()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isValid)
            .frame(maxWidth: 140, maxHeight: 32)
            .padding(DS3Spacing.lg)
        }
        .background(DS3Colors.secondaryBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(DS3Colors.separator),
            alignment: .top
        )
    }

    // MARK: - Validation

    private var isValid: Bool {
        !driveName.trimmingCharacters(in: .whitespaces).isEmpty && nameError == nil
    }

    private func validateName() {
        let trimmed = driveName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            nameError = "Drive name cannot be empty"
        } else {
            nameError = nil
        }
    }

    // MARK: - Create drive

    private func createDrive() {
        let trimmed = driveName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let drive = DS3Drive(
            id: UUID(),
            name: trimmed,
            syncAnchor: syncAnchor
        )

        onComplete?(drive)
    }

    // MARK: - Helpers

    private func displayPrefix(_ prefix: String) -> String {
        let decoded = prefix.removingPercentEncoding ?? prefix
        var display = decoded
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }
        return display
    }

    // MARK: - Modifiers

    func onBack(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onBack = action
        return copy
    }

    func onComplete(_ action: @escaping (DS3Drive) -> Void) -> Self {
        var copy = self
        copy.onComplete = action
        return copy
    }
}

#Preview {
    DriveConfirmView(
        syncAnchor: SyncAnchor(
            project: Project(
                id: "test-id",
                name: "My Project",
                description: "Test",
                email: "test@cubbit.io",
                createdAt: "2024-01-01",
                tenantId: "tenant",
                users: [
                    IAMUser(id: "user-id", username: "ROOT", isRoot: true)
                ]
            ),
            IAMUser: IAMUser(id: "user-id", username: "ROOT", isRoot: true),
            bucket: Bucket(name: "my-bucket"),
            prefix: "documents/"
        ),
        suggestedName: "my-bucket/documents"
    )
    .frame(width: 800, height: 480)
}
