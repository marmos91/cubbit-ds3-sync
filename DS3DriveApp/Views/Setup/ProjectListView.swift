#if os(iOS)
import SwiftUI
import DS3Lib

/// Searchable project list with shimmer loading placeholders.
/// First step of the drive setup wizard. Tap a project to navigate to its bucket list.
struct ProjectListView: View {
    var setupViewModel: SyncSetupViewModel
    @Binding var navigationPath: NavigationPath

    @Environment(DS3Authentication.self) private var ds3Authentication
    @State private var projectVM: ProjectSelectionViewModel?
    @State private var searchText = ""

    private var filteredProjects: [Project] {
        guard let projects = projectVM?.projects else { return [] }
        if searchText.isEmpty { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if projectVM?.loading == true {
                shimmerPlaceholder
            } else if let error = projectVM?.error {
                errorView(error)
            } else if filteredProjects.isEmpty {
                emptyView
            } else {
                projectList
            }
        }
        .searchable(text: $searchText, prompt: "Search projects")
        .refreshable {
            await projectVM?.loadProjects()
        }
        .navigationTitle("Select Project")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if projectVM == nil {
                let vm = ProjectSelectionViewModel(authentication: ds3Authentication)
                projectVM = vm
                await vm.loadProjects()
            }
        }
    }

    // MARK: - Shimmer Loading

    private var shimmerPlaceholder: some View {
        List {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: IOSSpacing.sm) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(IOSColors.secondaryText.opacity(0.3))
                        .frame(width: 32, height: 32)
                    Text("Loading project name")
                        .font(IOSTypography.body)
                }
                .iosShimmering()
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Error State

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(Color.red)
            Text("Could not load projects. Check your connection and try again.")
                .font(IOSTypography.body)
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)
            Button("Retry") {
                Task { await projectVM?.loadProjects() }
            }
            .buttonStyle(IOSPrimaryButtonStyle())
            .padding(.horizontal, IOSSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "tray.fill")
                .font(.largeTitle)
                .foregroundStyle(IOSColors.secondaryText)
            Text("No projects found. Create a project in the DS3 Console.")
                .font(IOSTypography.body)
                .foregroundStyle(IOSColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project List

    private var projectList: some View {
        List(filteredProjects) { project in
            Button {
                setupViewModel.selectProject(project: project)
                navigationPath.append(project)
            } label: {
                HStack(spacing: IOSSpacing.sm) {
                    projectEmblem(project.short())
                    Text(project.name)
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.primaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func projectEmblem(_ shortName: String) -> some View {
        Text(shortName.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange)
            )
    }
}
#endif
