# Tray Icons (placeholders)

These four `.ico` files are **placeholders** shipped by Phase 17 Plan 11 so the
`H.NotifyIcon.WinUI` `TaskbarIcon` has a state-based icon to swap (idle / syncing / paused /
error). They are flat 16×16 32bpp solid-colour icons using the status palette:

| File | State | Colour (status token) |
|------|-------|-----------------------|
| `icon-idle.ico` | Idle (all synced) | `StatusSuccess` `#26AB75` |
| `icon-syncing.ico` | Syncing (≥1 transferring) | `StatusSyncing` `#005CE8` |
| `icon-paused.ico` | Paused (≥1 paused, none syncing/error) | `StatusWarning` `#FFB74D` |
| `icon-error.ico` | Error (≥1 errored) | `StatusErrorMain` `#E56363` |

Final, polished assets (the base Cubbit mark + a status badge overlay, matching the macOS
menu-bar tray treatment) are produced by the design team in **Phase 18**. The colour masters
to derive them from live in `apple/DS3Drive/Assets.xcassets/MenuBarTray.imageset/` and the
status-badge imagesets referenced by `TrayDriveRowView.swift` (`statusIdleBadge`,
`statusSyncBadge`, `statusErrorBadge`).

The multi-state precedence the icon must reflect is **Error > Syncing > Paused > Idle**
(UI-SPEC §Interaction Contracts), computed by `TrayViewModel.AggregateStatus`.
