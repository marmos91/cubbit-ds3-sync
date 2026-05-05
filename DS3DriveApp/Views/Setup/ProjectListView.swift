#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Searchable project list — first step of the drive setup wizard.
    /// Mirrors the `IOSLoginView` design language: brand gradient backdrop,
    /// Figtree typography, and circular brand-tinted iconography for the
    /// empty / error states.
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
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                Group {
                    if projectVM?.loading == true {
                        shimmerPlaceholder
                    } else if let error = projectVM?.error ?? projectVM?.authenticationError {
                        errorView(error)
                    } else if filteredProjects.isEmpty {
                        emptyView
                    } else {
                        projectList
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $searchText, prompt: "Search projects")
            .refreshable {
                await projectVM?.loadProjects()
            }
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                if projectVM == nil {
                    let vm = ProjectSelectionViewModel(authentication: ds3Authentication)
                    projectVM = vm
                    await vm.loadProjects()
                }
            }
        }

        // MARK: - Project List

        private var projectList: some View {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredProjects) { project in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            setupViewModel.selectProject(project: project)
                            navigationPath.append(project)
                        } label: {
                            projectRow(project)
                        }
                        .buttonStyle(ProjectRowPressStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }

        private func projectRow(_ project: Project) -> some View {
            HStack(spacing: 14) {
                projectEmblem(project.short())

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.custom("Figtree-SemiBold", size: 16))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                        .lineLimit(1)

                    Text("Tap to choose a bucket")
                        .font(.custom("Figtree-Regular", size: 13))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
            )
        }

        private func projectEmblem(_ shortName: String) -> some View {
            Text(shortName.uppercased())
                .font(.custom("Figtree-SemiBold", size: 13))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    IOSColors.brandPrimary,
                                    IOSColors.brandPrimaryDark
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }

        // MARK: - Shimmer Loading

        private var shimmerPlaceholder: some View {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0 ..< 5, id: \.self) { _ in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(IOSColors.brandBorderSubtle)
                                .frame(width: 40, height: 40)

                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(IOSColors.brandBorderSubtle)
                                    .frame(width: 140, height: 14)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(IOSColors.brandBorderSubtle)
                                    .frame(width: 90, height: 11)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
                        )
                        .iosShimmering()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }

        // MARK: - Error State

        private var isAuthError: Bool {
            projectVM?.authenticationError != nil
        }

        private func errorView(_: Error) -> some View {
            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(IOSColors.statusError.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(IOSColors.statusError)
                }

                VStack(spacing: 8) {
                    Group {
                        if isAuthError {
                            Text("Session Expired")
                        } else {
                            Text("Couldn't Load Projects")
                        }
                    }
                    .font(.custom("Figtree-SemiBold", size: 20))
                    .foregroundStyle(IOSColors.brandTextPrimary)

                    Group {
                        if isAuthError {
                            Text("Your session has expired. Please log in again.")
                        } else {
                            Text("Check your connection and try again.")
                        }
                    }
                    .font(.custom("Figtree-Regular", size: 15))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isAuthError {
                        ds3Authentication.logout()
                    } else {
                        Task { await projectVM?.loadProjects() }
                    }
                } label: {
                    Group {
                        if isAuthError {
                            Text("Log Out")
                        } else {
                            Text("Retry")
                        }
                    }
                    .font(.custom("Figtree-SemiBold", size: 17))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(IOSColors.brandPrimary)
                    )
                }
                .buttonStyle(ProjectRowPressStyle())
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Empty State

        private var emptyView: some View {
            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(IOSColors.brandPrimary.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(IOSColors.brandPrimary)
                }

                VStack(spacing: 8) {
                    Group {
                        if searchText.isEmpty {
                            Text("No Projects Yet")
                        } else {
                            Text("No Matches")
                        }
                    }
                    .font(.custom("Figtree-SemiBold", size: 20))
                    .foregroundStyle(IOSColors.brandTextPrimary)

                    Group {
                        if searchText.isEmpty {
                            Text("Create a project in the DS3 Console to get started.")
                        } else {
                            Text("Try a different search term.")
                        }
                    }
                    .font(.custom("Figtree-Regular", size: 15))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row Press Style

    /// Subtle scale+opacity press feedback shared across tappable rows
    /// and CTAs in the setup wizard.
    private struct ProjectRowPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
