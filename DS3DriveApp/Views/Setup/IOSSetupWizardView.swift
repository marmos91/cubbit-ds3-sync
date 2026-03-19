#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Navigation Types

/// Carries bucket selection context through the navigation stack for prefix drill-down.
struct BucketSelection: Hashable {
    let project: Project
    let bucket: Bucket
    let prefix: String?
}

/// Sentinel value used to navigate to the confirm step via NavigationStack destination.
struct WizardConfirmStep: Hashable {
    let id = UUID()
}

// MARK: - Setup Wizard View

/// Full-screen cover wrapper with NavigationStack for drill-down wizard flow.
/// Flow: Project list -> Bucket list -> optional Prefix drill-down -> Confirm + Create Drive.
struct IOSSetupWizardView: View {
    @Environment(DS3Authentication.self) private var ds3Authentication
    @Environment(DS3DriveManager.self) private var ds3DriveManager
    @Environment(\.dismiss) private var dismiss

    @State private var setupViewModel = SyncSetupViewModel()
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ProjectListView(
                setupViewModel: setupViewModel,
                navigationPath: $navigationPath
            )
            .navigationDestination(for: Project.self) { project in
                BucketListView(
                    project: project,
                    setupViewModel: setupViewModel,
                    navigationPath: $navigationPath
                )
            }
            .navigationDestination(for: BucketSelection.self) { selection in
                PrefixListView(
                    selection: selection,
                    setupViewModel: setupViewModel,
                    navigationPath: $navigationPath
                )
            }
            .navigationDestination(for: WizardConfirmStep.self) { _ in
                DriveConfirmView(
                    setupViewModel: setupViewModel,
                    onDismiss: { dismiss() }
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(IOSColors.primaryText)
                    }
                }
            }
        }
    }
}
#endif
