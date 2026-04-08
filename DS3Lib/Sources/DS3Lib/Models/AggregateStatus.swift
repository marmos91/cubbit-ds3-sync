import Foundation

/// Single source of truth for the tray aggregate state (Gaps 15 + 27).
///
/// Derived purely from the set of per-drive `DS3DriveStatus` values so the
/// tray header, footer, drive rows, and menu bar icon can never disagree.
/// Replaces the ad-hoc `AppStatusManager` counter, which was prone to leaks.
///
/// The reducer lives in `from(statuses:)` — all consumers MUST go through it
/// rather than re-implementing priority rules locally. `AggregateStatusTests`
/// guards the behavior against regressions.
public enum AggregateStatus: Equatable, Sendable {
    /// No drives are registered. The tray surfaces should hide the aggregate row.
    case noDrives

    /// At least one drive exists and all are `.idle` (or a mix of idle and
    /// paused that still qualifies as "everything is healthy and at rest" is
    /// explicitly covered by `.allPaused` / `.mixed` — see reducer).
    case allIdle

    /// At least one drive is actively `.sync`. Wins over `.indexing` because
    /// transfers are the user-visible signal.
    case syncing

    /// At least one drive is `.indexing` and none are `.sync`.
    case indexing

    /// Every drive is in `.error`. `count` records how many so the UI can
    /// choose between "1 drive error" and "N drives error" copy.
    case error(count: Int)

    /// Every drive is `.paused` (user-initiated). No automatic work will run.
    case allPaused

    /// Mixed states that don't fit the above cleaner cases — e.g. one drive in
    /// `.error` and another still syncing / idle. The UI typically renders
    /// this as an error (it's the worst state in the set) but the value is
    /// distinct so callers can special-case the copy if they wish.
    case mixed

    // MARK: - Reducer

    /// Reduces a collection of per-drive statuses into the aggregate surface.
    ///
    /// Priority order:
    ///  1. empty           → `.noDrives`
    ///  2. all `.error`    → `.error(count:)`
    ///  3. all `.paused`   → `.allPaused`
    ///  4. any `.error`    → `.mixed` (error coexists with a healthy state)
    ///  5. any `.sync`     → `.syncing`
    ///  6. any `.indexing` → `.indexing`
    ///  7. otherwise       → `.allIdle`
    public static func from(statuses: [DS3DriveStatus]) -> AggregateStatus {
        if statuses.isEmpty { return .noDrives }

        let errorCount = statuses.count(where: { $0 == .error })
        let pausedCount = statuses.count(where: { $0 == .paused })

        if errorCount == statuses.count { return .error(count: errorCount) }
        if pausedCount == statuses.count { return .allPaused }
        if errorCount > 0 { return .mixed }
        if statuses.contains(.sync) { return .syncing }
        if statuses.contains(.indexing) { return .indexing }
        return .allIdle
    }

    // MARK: - AppStatus bridge

    /// Legacy bridge so the existing `TrayMenuFooterView` / menu-bar icon
    /// bindings (which switch on `AppStatus`) keep working until a future
    /// cleanup pass removes `AppStatus` entirely.
    public var appStatus: AppStatus {
        switch self {
        case .noDrives, .allIdle: .idle
        case .syncing: .syncing
        case .indexing: .indexing
        case .error, .mixed: .error
        case .allPaused: .paused
        }
    }

    /// Whether the aggregate row should be shown in the tray header. Hidden
    /// when there are no drives — the per-row state is the only signal.
    public var shouldShowInTrayHeader: Bool {
        switch self {
        case .noDrives: false
        default: true
        }
    }
}
