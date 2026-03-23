// swiftlint:disable file_length
import SwiftUI
import os.log
import DS3Lib

/// A tree node representing an item in the project > bucket > prefix hierarchy
@MainActor @Observable class TreeNode: Identifiable {
    let id: String
    let name: String
    let type: TreeNodeType
    var children: [TreeNode] = []
    var isExpanded: Bool = false
    var isLoading: Bool = false
    var isLoaded: Bool = false

    /// Associated data for building a SyncAnchor
    var project: Project?
    var bucket: Bucket?
    var prefix: String?

    enum TreeNodeType {
        case project
        case bucket
        case folder
    }

    init(id: String, name: String, type: TreeNodeType, project: Project? = nil, bucket: Bucket? = nil, prefix: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.project = project
        self.bucket = bucket
        self.prefix = prefix
    }
}

/// ViewModel that manages the tree navigation hierarchy and S3 operations
@MainActor @Observable class TreeNavigationViewModel {
    typealias Logger = os.Logger
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    var authentication: DS3Authentication
    var projectNodes: [TreeNode] = []
    var isLoadingProjects: Bool = true
    var error: Error?

    var selectedNode: TreeNode?

    /// Selected IAM user per project (keyed by project ID). Defaults to first user.
    var selectedIAMUsers: [String: IAMUser] = [:]

    private var ds3SDK: DS3SDK
    /// Active DS3S3Client per project (keyed by project ID)
    @ObservationIgnored nonisolated(unsafe) private var s3Clients: [String: DS3S3Client] = [:]

    init(authentication: DS3Authentication) {
        self.authentication = authentication
        self.ds3SDK = DS3SDK(withAuthentication: authentication)
    }

    func shutdownClients() {
        for (_, client) in s3Clients {
            try? client.shutdown()
        }
    }

    // MARK: - Load projects

    func loadProjects() async {
        self.isLoadingProjects = true
        self.error = nil

        async let fetch: [Project] = ds3SDK.getRemoteProjects()
        async let minDelay: () = Task.sleep(for: .seconds(1))

        do {
            let projects = try await fetch
            _ = try? await minDelay

            self.projectNodes = projects
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { project in
                    TreeNode(id: project.id, name: project.name, type: .project, project: project)
                }
        } catch {
            self.logger.error("Failed to load projects: \(error)")
            self.error = error
        }

        self.isLoadingProjects = false
    }

    func refresh() async {
        // Capture expansion state and selection before clearing
        let expandedIDs = collectExpandedIDs()
        let selectedID = selectedNode?.id

        self.selectedNode = nil
        for (_, client) in s3Clients { try? client.shutdown() }
        self.s3Clients.removeAll()

        await loadProjects()
        await restoreExpansion(expandedIDs: expandedIDs, selectedID: selectedID)
    }

    // MARK: - Expansion state preservation

    private func collectExpandedIDs() -> Set<String> {
        func gather(from nodes: [TreeNode]) -> Set<String> {
            var ids = Set<String>()
            for node in nodes where node.isExpanded {
                ids.insert(node.id)
                ids.formUnion(gather(from: node.children))
            }
            return ids
        }
        return gather(from: projectNodes)
    }

    private func restoreExpansion(expandedIDs: Set<String>, selectedID: String?) async {
        guard !expandedIDs.isEmpty else { return }

        for projectNode in projectNodes where expandedIDs.contains(projectNode.id) {
            await expandProject(projectNode)
            for bucketNode in projectNode.children where expandedIDs.contains(bucketNode.id) {
                await expandBucket(bucketNode)
                await restoreFolderExpansion(children: bucketNode.children, expandedIDs: expandedIDs)
            }
        }

        // Restore selection
        if let selectedID {
            selectedNode = findNode(withID: selectedID)
        }
    }

    private func restoreFolderExpansion(children: [TreeNode], expandedIDs: Set<String>) async {
        for folderNode in children where expandedIDs.contains(folderNode.id) {
            await expandFolder(folderNode)
            await restoreFolderExpansion(children: folderNode.children, expandedIDs: expandedIDs)
        }
    }

    private func findNode(withID id: String) -> TreeNode? {
        func search(in nodes: [TreeNode]) -> TreeNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(in: node.children) { return found }
            }
            return nil
        }
        return search(in: projectNodes)
    }

    // MARK: - Expand project -> load buckets

    func expandProject(_ node: TreeNode) async {
        guard let project = node.project, !node.isLoaded else { return }

        node.isLoading = true
        defer { node.isLoading = false }

        do {
            let s3Client = try await getOrCreateS3Client(forProject: project)
            let buckets = try await s3Client.listBuckets()

            node.children = buckets
                .map { bucketInfo in
                    let bucket = Bucket(name: bucketInfo.name)
                    return TreeNode(
                        id: "\(project.id)/\(bucket.name)",
                        name: bucket.name,
                        type: .bucket,
                        project: project,
                        bucket: bucket
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            node.isLoaded = true
            node.isExpanded = true
        } catch {
            self.logger.error("Failed to load buckets for project \(project.name): \(error)")
            self.error = error
        }
    }

    // MARK: - Expand bucket -> load folder prefixes

    func expandBucket(_ node: TreeNode) async {
        guard let project = node.project, let bucket = node.bucket, !node.isLoaded else { return }

        node.isLoading = true
        defer { node.isLoading = false }

        do {
            let s3Client = try await getOrCreateS3Client(forProject: project)
            let result = try await s3Client.listObjects(
                bucket: bucket.name,
                delimiter: String(DefaultSettings.S3.delimiter)
            )

            node.children = result.commonPrefixes.compactMap { decoded -> TreeNode? in
                let displayName = folderDisplayName(fullPrefix: decoded, parentPrefix: nil)
                return TreeNode(
                    id: "\(project.id)/\(bucket.name)/\(decoded)",
                    name: displayName,
                    type: .folder,
                    project: project,
                    bucket: bucket,
                    prefix: decoded
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            node.isLoaded = true
            node.isExpanded = true
        } catch {
            self.logger.error("Failed to load folders for bucket \(bucket.name): \(error)")
            self.error = error
        }
    }

    // MARK: - Expand a folder prefix -> load sub-prefixes

    func expandFolder(_ node: TreeNode) async {
        guard let project = node.project, let bucket = node.bucket, let prefix = node.prefix, !node.isLoaded else {
            // Already loaded — just expand
            if node.isLoaded { node.isExpanded = true }
            return
        }

        node.isLoading = true
        defer {
            node.isLoading = false
            node.isLoaded = true
        }

        do {
            let s3Client = try await getOrCreateS3Client(forProject: project)
            // prefix is already decoded (stored decoded from expandBucket)
            let result = try await s3Client.listObjects(
                bucket: bucket.name,
                prefix: prefix,
                delimiter: String(DefaultSettings.S3.delimiter)
            )

            node.children = result.commonPrefixes.map { decoded -> TreeNode in
                let displayName = folderDisplayName(fullPrefix: decoded, parentPrefix: prefix)
                return TreeNode(
                    id: "\(project.id)/\(bucket.name)/\(decoded)",
                    name: displayName,
                    type: .folder,
                    project: project,
                    bucket: bucket,
                    prefix: decoded
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            node.isExpanded = true
        } catch {
            self.logger.error("Failed to load sub-folders for prefix \(prefix): \(error)")
            self.error = error
        }
    }

    // MARK: - Toggle expand/collapse

    func toggleNode(_ node: TreeNode) async {
        if node.isExpanded {
            node.isExpanded = false
            return
        }

        // Already loaded — just re-expand without fetching
        if node.isLoaded {
            node.isExpanded = true
            return
        }

        switch node.type {
        case .project:
            await expandProject(node)
        case .bucket:
            await expandBucket(node)
        case .folder:
            await expandFolder(node)
        }
    }

    // MARK: - Selection

    func selectNode(_ node: TreeNode) {
        selectedNode = node
    }

    /// Returns the selected IAM user for a project, defaulting to the first user.
    func selectedIAMUser(forProject project: Project) -> IAMUser? {
        selectedIAMUsers[project.id] ?? project.users.first
    }

    /// Switch the IAM user for a project, invalidating cached S3 clients and reloading buckets.
    func selectIAMUser(_ user: IAMUser, forProject project: Project) async {
        selectedIAMUsers[project.id] = user
        selectedNode = nil

        // Invalidate cached S3 client for this project
        if let awsClient = awsClients[project.id] {
            try? awsClient.syncShutdown()
            awsClients.removeValue(forKey: project.id)
        }
        s3Clients.removeValue(forKey: project.id)

        // Collapse and reload the project node's children
        if let projectNode = projectNodes.first(where: { $0.id == project.id }) {
            projectNode.children = []
            projectNode.isLoaded = false
            projectNode.isExpanded = false
            await expandProject(projectNode)
        }
    }

    /// Builds a SyncAnchor from the currently selected node (must be a bucket or folder)
    func getSelectedSyncAnchor() -> SyncAnchor? {
        guard let node = selectedNode else { return nil }
        guard let project = node.project, let bucket = node.bucket else { return nil }
        guard let user = selectedIAMUser(forProject: project) else { return nil }

        return SyncAnchor(
            project: project,
            IAMUser: user,
            bucket: bucket,
            prefix: node.prefix
        )
    }

    var canContinue: Bool {
        guard let node = selectedNode else { return false }
        return node.type != .project
    }

    // MARK: - Helpers

    private func getOrCreateS3Client(forProject project: Project) async throws -> DS3S3Client {
        if let existing = s3Clients[project.id] {
            return existing
        }

        guard let iamUser = selectedIAMUser(forProject: project) else {
            throw SyncAnchorSelectionError.noIAMUserSelected
        }

        guard let account = authentication.account else {
            throw SyncAnchorSelectionError.DS3ClientError
        }

        let apiKeys = try await ds3SDK.loadOrCreateDS3APIKeys(
            forIAMUser: iamUser,
            ds3ProjectName: project.name
        )

        guard let secretKey = apiKeys.secretKey else {
            throw SyncAnchorSelectionError.DS3ClientError
        }

        let client = DS3S3Client(
            accessKeyId: apiKeys.apiKey,
            secretAccessKey: secretKey,
            endpoint: account.endpointGateway
        )

        s3Clients[project.id] = client
        return client
    }

    /// Extracts a display name from a decoded prefix by stripping the parent path and trailing slash.
    /// Both `fullPrefix` and `parentPrefix` are expected to be already percent-decoded.
    private func folderDisplayName(fullPrefix: String, parentPrefix: String?) -> String {
        var display = fullPrefix

        if let parent = parentPrefix, display.hasPrefix(parent) {
            display = String(display.dropFirst(parent.count))
        }

        return display.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - TreeNavigationView

struct TreeNavigationView: View {
    @State var viewModel: TreeNavigationViewModel

    var onSyncAnchorSelected: ((SyncAnchor) -> Void)?

    init(authentication: DS3Authentication) {
        self._viewModel = State(initialValue: TreeNavigationViewModel(authentication: authentication))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar: tree view
            treeSidebar
                .frame(width: 280)
                .border(width: 1, edges: [.trailing], color: DS3Colors.separator)

            // Right content: selection details + continue button
            detailPanel
        }
        .task {
            await viewModel.loadProjects()
        }
        .onDisappear {
            viewModel.shutdownClients()
        }
    }

    // MARK: - Tree sidebar

    @ViewBuilder
    private var treeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Select a bucket")
                    .font(DS3Typography.headline)
                    .foregroundStyle(DS3Colors.primaryText)

                Spacer()

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(viewModel.isLoadingProjects)
                .help("Refresh projects and buckets")
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.top, 36)
            .padding(.bottom, DS3Spacing.sm)

            if viewModel.isLoadingProjects {
                shimmerPlaceholder
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.projectNodes) { node in
                            treeRow(node: node, depth: 0)
                        }
                    }
                    .padding(.horizontal, DS3Spacing.sm)
                    .padding(.vertical, DS3Spacing.sm)
                }
            }
        }
        .background(DS3Colors.secondaryBackground)
    }

    // MARK: - Recursive tree row

    private func treeRow(node: TreeNode, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS3Spacing.xs) {
                    // Expand/collapse chevron
                    if node.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else if canExpand(node) {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                            .frame(width: 16, height: 16)
                    } else {
                        Spacer()
                            .frame(width: 16, height: 16)
                    }

                    // Icon
                    iconView(for: node)

                    // Name
                    Text(node.name)
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()
                }
                .padding(.vertical, DS3Spacing.xs)
                .padding(.leading, CGFloat(depth) * 20 + DS3Spacing.sm)
                .padding(.trailing, DS3Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(viewModel.selectedNode?.id == node.id ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
                .pointingHandCursor()
                .onTapGesture {
                    viewModel.selectNode(node)
                    Task {
                        await viewModel.toggleNode(node)
                    }
                }

                // Children (expanded)
                if node.isExpanded {
                    ForEach(node.children) { child in
                        treeRow(node: child, depth: depth + 1)
                    }
                }
            }
        )
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            if let node = viewModel.selectedNode {
                VStack(spacing: DS3Spacing.md) {
                    detailIconView(for: node)

                    Text(node.name)
                        .font(DS3Typography.title)
                        .foregroundStyle(DS3Colors.primaryText)

                    Text(detailDescription(for: node))
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.secondaryText)
                        .multilineTextAlignment(.center)

                }
                .padding(DS3Spacing.xl)
            } else {
                VStack(spacing: DS3Spacing.md) {
                    Image(systemName: "arrow.left.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(DS3Colors.secondaryText)

                    Text("Select a project, bucket, or folder from the tree")
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(DS3Spacing.xl)
            }

            Spacer()

            // Error display
            if let error = viewModel.error {
                Text(error.localizedDescription)
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.statusError)
                    .padding(.horizontal, DS3Spacing.lg)
                    .padding(.bottom, DS3Spacing.sm)
            }

            // IAM user picker in footer area
            if let node = viewModel.selectedNode, let project = node.project {
                VStack(spacing: DS3Spacing.xs) {
                    Text("Switch IAM user to browse buckets with different permissions")
                        .font(DS3Typography.caption)
                        .foregroundStyle(DS3Colors.secondaryText)
                        .multilineTextAlignment(.center)

                    iamUserPicker(forProject: project)
                }
                .padding(.horizontal, DS3Spacing.lg)
                .padding(.bottom, DS3Spacing.sm)
            }

            // Footer with Continue button
            HStack {
                Spacer()
                Button("Continue") {
                    if let anchor = viewModel.getSelectedSyncAnchor() {
                        onSyncAnchorSelected?(anchor)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!viewModel.canContinue)
                .frame(maxWidth: 120, maxHeight: 32)
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
        .background(DS3Colors.background)
    }

    // MARK: - IAM User Picker

    @ViewBuilder
    private func iamUserPicker(forProject project: Project) -> some View {
        let currentUser = viewModel.selectedIAMUser(forProject: project)

        Menu {
            ForEach(project.users, id: \.id) { user in
                Button {
                    Task { await viewModel.selectIAMUser(user, forProject: project) }
                } label: {
                    HStack {
                        Text(user.username)
                        if user.isRoot {
                            Text("(root)")
                                .foregroundStyle(.secondary)
                        }
                        if user.id == currentUser?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: DS3Spacing.xs) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS3Colors.secondaryText)

                Text(currentUser?.username ?? "Select user")
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(DS3Colors.secondaryText)
            }
            .padding(.horizontal, DS3Spacing.sm)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(DS3Colors.separator.opacity(0.3))
            )
            .overlay(
                Capsule()
                    .stroke(DS3Colors.separator, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .padding(.top, DS3Spacing.xs)
    }

    // MARK: - Shimmer placeholder

    @ViewBuilder
    private var shimmerPlaceholder: some View {
        VStack(alignment: .leading, spacing: DS3Spacing.sm) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: DS3Spacing.sm) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS3Colors.separator)
                        .frame(width: 16, height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS3Colors.separator)
                        .frame(height: 16)
                }
                .padding(.horizontal, DS3Spacing.lg)
            }
        }
        .padding(.vertical, DS3Spacing.md)
        .shimmering()
    }

    // MARK: - Helpers

    private func canExpand(_ node: TreeNode) -> Bool {
        switch node.type {
        case .project, .bucket:
            return true
        case .folder:
            return node.isLoaded ? !node.children.isEmpty : true
        }
    }

    @ViewBuilder
    private func iconView(for node: TreeNode) -> some View {
        switch node.type {
        case .project:
            Text(node.project?.short().uppercased() ?? "")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange)
                )
        case .bucket:
            Image(.bucketIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .folder:
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(DS3Typography.body)
        }
    }

    @ViewBuilder
    private func detailIconView(for node: TreeNode) -> some View {
        switch node.type {
        case .project:
            Text(node.project?.short().uppercased() ?? "")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange)
                )
        case .bucket:
            Image(.bucketIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }

    private func detailDescription(for node: TreeNode) -> String {
        switch node.type {
        case .project: return "Expand to browse buckets in this project"
        case .bucket: return "Select this bucket to sync, or expand to choose a folder prefix"
        case .folder: return "Sync files from this folder prefix"
        }
    }

    func onSyncAnchorSelected(_ action: @escaping (SyncAnchor) -> Void) -> Self {
        var copy = self
        copy.onSyncAnchorSelected = action
        return copy
    }
}
