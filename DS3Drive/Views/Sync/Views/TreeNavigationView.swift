import SwiftUI
import SotoS3
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

    private var ds3SDK: DS3SDK
    /// Active S3 client per project (keyed by project ID)
    private var s3Clients: [String: S3] = [:]
    nonisolated(unsafe) private var awsClients: [String: AWSClient] = [:]

    init(authentication: DS3Authentication) {
        self.authentication = authentication
        self.ds3SDK = DS3SDK(withAuthentication: authentication)
    }

    deinit {
        for (_, client) in awsClients {
            try? client.syncShutdown()
        }
    }

    // MARK: - Load projects

    func loadProjects() async {
        self.isLoadingProjects = true
        self.error = nil
        defer { self.isLoadingProjects = false }

        do {
            let projects = try await ds3SDK.getRemoteProjects()
            self.projectNodes = projects.map { project in
                let node = TreeNode(id: project.id, name: project.name, type: .project, project: project)
                return node
            }
        } catch {
            self.logger.error("Failed to load projects: \(error)")
            self.error = error
        }
    }

    // MARK: - Expand project -> load buckets

    func expandProject(_ node: TreeNode) async {
        guard let project = node.project, !node.isLoaded else { return }

        node.isLoading = true
        defer { node.isLoading = false }

        do {
            let s3Client = try await getOrCreateS3Client(forProject: project)
            let response = try await s3Client.listBuckets()
            let buckets = response.buckets ?? []

            node.children = buckets.map { s3Bucket in
                let bucket = Bucket(name: s3Bucket.name ?? "<No name>")
                return TreeNode(
                    id: "\(project.id)/\(bucket.name)",
                    name: bucket.name,
                    type: .bucket,
                    project: project,
                    bucket: bucket
                )
            }

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
            let request = S3.ListObjectsV2Request(
                bucket: bucket.name,
                delimiter: String(DefaultSettings.S3.delimiter),
                encodingType: .url
            )

            let response = try await s3Client.listObjectsV2(request)
            let prefixes = response.commonPrefixes ?? []

            node.children = prefixes.compactMap { commonPrefix -> TreeNode? in
                guard let fullPrefix = commonPrefix.prefix else { return nil }
                // Decode URL-encoded prefix for display and storage
                let decoded = fullPrefix.removingPercentEncoding ?? fullPrefix
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
            let request = S3.ListObjectsV2Request(
                bucket: bucket.name,
                delimiter: String(DefaultSettings.S3.delimiter),
                encodingType: .url,
                prefix: prefix
            )

            let response = try await s3Client.listObjectsV2(request)
            let prefixes = response.commonPrefixes ?? []

            node.children = prefixes.compactMap { commonPrefix -> TreeNode? in
                guard let fullPrefix = commonPrefix.prefix else { return nil }
                let decoded = fullPrefix.removingPercentEncoding ?? fullPrefix
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

    /// Builds a SyncAnchor from the currently selected node (must be a bucket or folder)
    func getSelectedSyncAnchor() -> SyncAnchor? {
        guard let node = selectedNode else { return nil }
        guard let project = node.project, let bucket = node.bucket else { return nil }

        let iamUser = project.users.first
        guard let user = iamUser else { return nil }

        return SyncAnchor(
            project: project,
            IAMUser: user,
            bucket: bucket,
            prefix: node.prefix
        )
    }

    var canContinue: Bool {
        guard let node = selectedNode else { return false }
        return node.type == .bucket || node.type == .folder
    }

    // MARK: - Helpers

    private func getOrCreateS3Client(forProject project: Project) async throws -> S3 {
        if let existing = s3Clients[project.id] {
            return existing
        }

        guard let iamUser = project.users.first else {
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

        let awsClient = AWSClient(
            credentialProvider: .static(
                accessKeyId: apiKeys.apiKey,
                secretAccessKey: secretKey
            ),
            httpClientProvider: .createNew
        )

        let s3Client = S3(client: awsClient, endpoint: account.endpointGateway)
        awsClients[project.id] = awsClient
        s3Clients[project.id] = s3Client

        return s3Client
    }

    private func folderDisplayName(fullPrefix: String, parentPrefix: String?) -> String {
        let decoded = fullPrefix.removingPercentEncoding ?? fullPrefix
        var display = decoded

        if let parent = parentPrefix?.removingPercentEncoding, decoded.hasPrefix(parent) {
            display = String(decoded.dropFirst(parent.count))
        }

        // Remove trailing slash for display
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }

        return display
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
    }

    // MARK: - Tree sidebar

    @ViewBuilder
    private var treeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select a bucket")
                .font(DS3Typography.headline)
                .foregroundStyle(DS3Colors.primaryText)
                .padding(.horizontal, DS3Spacing.lg)
                .padding(.top, 36)
                .padding(.bottom, DS3Spacing.sm)

            if viewModel.isLoadingProjects {
                shimmerPlaceholder
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
                    Image(systemName: iconForNode(node))
                        .foregroundStyle(iconColorForNode(node))
                        .font(DS3Typography.body)

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
                    Image(systemName: iconForNode(node))
                        .font(.system(size: 40))
                        .foregroundStyle(iconColorForNode(node))

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

    private func iconForNode(_ node: TreeNode) -> String {
        switch node.type {
        case .project: return "cube.fill"
        case .bucket: return "cylinder"
        case .folder: return "folder"
        }
    }

    private func iconColorForNode(_ node: TreeNode) -> Color {
        switch node.type {
        case .project: return .orange
        case .bucket: return .accentColor
        case .folder: return .secondary
        }
    }

    private func detailDescription(for node: TreeNode) -> String {
        switch node.type {
        case .project:
            return "Expand to browse buckets in this project"
        case .bucket:
            return "Select this bucket to sync, or expand to choose a folder prefix"
        case .folder:
            return "Sync files from this folder prefix"
        }
    }

    // MARK: - Modifier

    func onSyncAnchorSelected(_ action: @escaping (SyncAnchor) -> Void) -> Self {
        var copy = self
        copy.onSyncAnchorSelected = action
        return copy
    }
}

#Preview {
    TreeNavigationView(
        authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
    )
    .frame(width: 800, height: 480)
}
