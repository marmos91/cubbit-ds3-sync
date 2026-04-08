import DS3Lib
import SwiftUI

struct DriveConfirmView: View {
    var syncAnchor: SyncAnchor
    @State private var driveName: String

    var onBack: (() -> Void)?
    var onComplete: ((DS3Drive) -> Void)?

    @State private var nameError: String?
    @FocusState private var driveNameFocused: Bool

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
                    .font(DS3Typography.h3)
                    .foregroundStyle(DS3Colors.brandTextPrimary)

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
        .background(DS3Colors.brandBackground)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                driveNameFocused = true
            }
        }
    }

    // MARK: - Summary section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(label: "Project") {
                ProjectBadge(
                    projectId: syncAnchor.project.id,
                    projectName: syncAnchor.project.name,
                    size: 24
                )
                Text(syncAnchor.project.name)
            }

            Divider().padding(.leading, 70)

            summaryRow(label: "Bucket") {
                Image(.bucketIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(syncAnchor.bucket.name)
            }

            if let prefix = syncAnchor.prefix, !prefix.isEmpty {
                Divider().padding(.leading, 70)

                summaryRow(label: "Path") {
                    Image(systemName: "folder")
                        .foregroundStyle(DS3Colors.brandTextSecondary)
                        .font(.system(size: 13))
                    Text(displayPrefix(prefix))
                }
            }
        }
        .brandCard()
    }

    private func summaryRow(label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: DS3Spacing.sm) {
            Text(label)
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandTextSecondary)
                .frame(width: 54, alignment: .leading)

            content()
                .font(DS3Typography.body)
                .foregroundStyle(DS3Colors.brandTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, DS3Spacing.sm)
    }

    // MARK: - Name section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DS3Spacing.sm) {
            Text("Drive name")
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandTextSecondary)

            TextField("Enter drive name", text: $driveName)
                .textFieldStyle(.roundedBorder)
                .font(DS3Typography.body)
                .focused($driveNameFocused)
                .onSubmit {
                    if isValid { createDrive() }
                }
                .onChange(of: driveName) {
                    validateName()
                }

            if let nameError {
                Text(nameError)
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.statusError)
            }

            Text(
                "With a single drive, Finder displays the app name in the sidebar. This name will be shown when multiple drives are configured. [Learn more](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/displayname)"
            )
            .font(DS3Typography.footnote)
            .foregroundStyle(DS3Colors.brandTextSecondary)
        }
    }

    // MARK: - Footer bar

    private var footerBar: some View {
        HStack {
            Button {
                onBack?()
            } label: {
                HStack(spacing: DS3Spacing.xs) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                        .font(DS3Typography.body)
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .padding(.leading, DS3Spacing.lg)

            Spacer()

            Button("Create Drive") {
                createDrive()
            }
            .buttonStyle(BrandPrimaryButtonStyle())
            .disabled(!isValid)
            .keyboardShortcut(.defaultAction)
            .padding(DS3Spacing.lg)
        }
        .background(DS3Colors.brandSurface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(DS3Colors.brandBorderSubtle),
            alignment: .top
        )
    }

    // MARK: - Validation

    private var isValid: Bool {
        !driveName.trimmingCharacters(in: .whitespaces).isEmpty && nameError == nil
    }

    private func validateName() {
        // Enforce max length to prevent excessively long domain names
        if driveName.count > 64 {
            driveName = String(driveName.prefix(64))
        }
        let trimmed = driveName.trimmingCharacters(in: .whitespaces)
        nameError = trimmed.isEmpty ? "Drive name cannot be empty" : nil
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
        prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
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
        syncAnchor: PreviewData.syncAnchor,
        suggestedName: "my-bucket/Documents"
    )
    .frame(width: 800, height: 480)
}
