# Feature Landscape

**Domain:** Consumer-focused cloud file sync (macOS desktop client)
**Researched:** 2026-03-11

## Table Stakes

Features users expect. Missing = product feels incomplete or broken.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Automatic bidirectional sync** | Core premise of sync client; files must sync reliably without manual intervention | Medium | DS3 Sync has this but needs stability improvements |
| **On-demand/smart sync** | Modern standard (Dropbox Smart Sync, Google Drive Stream, OneDrive Files on Demand); saves local disk space | Medium | DS3 Sync has this via File Provider |
| **Selective sync** | Users need control over what syncs to avoid filling disk | Low | Standard folder selection UI |
| **Offline access** | Files marked for offline use must be accessible without network | Low | File Provider handles this automatically |
| **File status indicators** | Users must see sync state (syncing, synced, cloud-only, error) per file | Medium | **MISSING** in DS3 Sync; ExpanDrive/Mountain Duck have Finder overlays |
| **Version history** | Accidental overwrites happen; users expect rollback (30-180 days standard) | High | Requires versioned S3 bucket support (planned, not implemented) |
| **Conflict resolution** | Multiple devices editing same file must not cause silent data loss | High | **MISSING**; needs conflict copy strategy (Dropbox pattern) |
| **Menu bar status** | Persistent indicator of sync state, quick access to settings/drives | Low | Exists but broken in DS3 Sync |
| **Pause/resume sync** | Network congestion or metered connections require user control | Low | Common in all competitors |
| **Login/auth flow** | Seamless authentication without exposing API internals | Medium | DS3 Sync exposes too much (tenant, API keys); needs simplification |
| **Multi-device support** | Same account syncs across multiple Macs | Low | Standard cloud sync behavior |
| **Large file support** | Multipart upload for files >5MB; block-level sync for efficiency | Medium | DS3 Sync has multipart upload; block-level sync would improve performance |
| **Background sync** | Sync must continue when app window closed; survives sleep/wake | Medium | File Provider architecture handles this |
| **Network resilience** | Retry failed uploads/downloads automatically; handle interrupted connections | Medium | Needs improvement in DS3 Sync (error handling gaps) |
| **Setup wizard** | First-run experience to configure drives without technical knowledge | Low | Exists but needs UX polish |

**Dependencies:**
```
Conflict resolution → Version history (needs ETag/version comparison)
File status indicators → Local metadata DB (sync state tracking)
Background sync → File Provider extension (architectural requirement)
```

## Differentiators

Features that set product apart. Not expected, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Open source (GPL)** | Transparency, auditability, community trust; rare in sync clients | N/A | DS3 Drive's key differentiator vs ExpanDrive/Mountain Duck |
| **Cubbit-native integration** | Auto-discover S3 endpoints via Composer Hub; seamless tenant/project selection | Medium | Unique to DS3 ecosystem; hides complexity |
| **Sovereign/distributed storage** | Data sovereignty via geo-distributed Cubbit swarm (vs centralized AWS/GCP) | N/A | Cubbit platform value, not app feature |
| **Multiple independent drives** | Up to 3 separate sync folders (different projects/tenants) mounted simultaneously | Medium | DS3 Sync supports this; rare in free/consumer tools |
| **Zero-knowledge encryption** | End-to-end encryption where server can't decrypt files | High | Planned future feature; high security value |
| **Free for personal use** | No subscription required for individual users | N/A | Business model decision; matches ExpanDrive post-merger |
| **Native Apple integration** | File Provider API = Finder-native experience (not FUSE mount) | Medium | Architectural choice; better UX than rclone |
| **Simplified API key management** | Auto-create/rotate keys behind the scenes; user never sees credentials | Medium | Planned; reduces friction vs current DS3 Sync |
| **Transfer speed visibility** | Real-time upload/download speeds in menu bar | Low | Missing from DS3 Sync; common in competitors |
| **Recent files quick access** | Menu bar shows recently synced files for quick re-opening | Low | Nice-to-have for productivity |

**Dependencies:**
```
Cubbit-native integration → Composer Hub APIs (tenant routing, project discovery)
Multiple drives → Separate File Provider domains per drive
Zero-knowledge encryption → Client-side encryption layer before S3 upload
```

## Anti-Features

Features to explicitly NOT build.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Multi-cloud support** | Scope creep; DS3 Drive is Cubbit-native, not generic S3 client | Focus on Cubbit-specific value (auto-discovery, sovereign storage) |
| **Built-in file editor** | Not core to sync; bloats app; users have preferred tools | Integrate with system default apps via Finder |
| **AI/ML features** | Trend-chasing; adds complexity/cost; unclear user value for sync | Let Cubbit platform handle AI if needed (not app responsibility) |
| **Social/collaboration features** | Out of scope for v1; requires backend infrastructure DS3 doesn't have | Defer to future (public links, shared folders require access control layer) |
| **Windows/Linux clients** | macOS-first strategy; File Provider is Apple-specific | Focus on quality macOS experience; iOS/iPadOS next (same codebase) |
| **Custom cloud backend** | Increases maintenance; S3 + Coordinator APIs are sufficient | Use existing Cubbit infrastructure only |
| **Bandwidth throttling** | Added complexity; modern networks rarely need this | Defer to future if users request |
| **Spotlight indexing** | High complexity; requires content extraction; diminishing returns | Defer to future; ExpanDrive has this but not critical for v1 |
| **Thumbnail generation** | Performance cost; File Provider can delegate to system | Defer to future; let macOS QuickLook handle previews |

## Feature Dependencies

```
File status overlays → Local metadata DB (track sync state per file)
Conflict resolution → Local metadata DB (store ETag, LastModified, local hash)
Version history → Versioned S3 buckets (backend requirement)
Remote deletion tracking → Change enumeration with S3 ListObjects comparison
Offline access → File Provider downloading + local cache
On-demand sync → File Provider NSFileProviderItem.capabilities
Transfer speed → Network activity monitoring + UI updates
Recent files → Local activity log (DB or UserDefaults)
```

## MVP Recommendation

Prioritize (Phase 1 - Core Stability):
1. **Conflict resolution** (table stakes, prevents data loss)
2. **File status indicators** (table stakes, user visibility)
3. **Local metadata DB** (enables above two + remote deletion tracking)
4. **Stable sync engine** (fix blocking issues, improve error handling)
5. **Menu bar polish** (table stakes, currently broken)
6. **Simplified auth UX** (differentiator, reduces friction)
7. **Multiple drives support** (differentiator, already partially implemented)

Defer to Phase 2 (Polish & Differentiation):
- **Version history**: Requires versioned bucket support (backend dependency)
- **Transfer speed visibility**: Nice-to-have, not blocking
- **Recent files quick access**: Nice-to-have, not blocking
- **Block-level sync**: Performance optimization, not correctness issue

Defer to Future:
- **Zero-knowledge encryption**: High complexity, separate security initiative
- **Spotlight indexing**: Low ROI for v1
- **Thumbnail generation**: System handles this adequately
- **Bandwidth throttling**: Not requested by users yet

**Rationale:**
Focus on **correctness and reliability first** (conflict resolution, stable sync, status visibility), then **UX polish** (simplified auth, menu bar), then **differentiation** (Cubbit-native integration, multiple drives). Version history and advanced features come later once core sync is rock-solid.

## Sources

**Dropbox:**
- [Dropbox Sync Features](https://www.dropbox.com/features/sync)
- [Dropbox Review 2026 (SaaS CRM Review)](https://saascrmreview.com/dropbox-review/)
- [Dropbox Selective Sync](https://help.dropbox.com/sync/selective-sync-overview)

**Google Drive:**
- [Google Drive Complete Guide 2026](https://cloudmounter.net/what-is-google-drive-guide/)
- [Google Drive Review 2026 (Cloudwards)](https://www.cloudwards.net/review/google-drive/)
- [Google Drive Differential Sync](https://www.techzine.eu/news/applications/127732/google-drive-is-faster-than-ever-due-to-new-sync-technique/)

**OneDrive:**
- [OneDrive Release Notes (Microsoft)](https://support.microsoft.com/en-us/office/onedrive-release-notes-845dcf18-f921-435e-bf28-4e24b95e5fc0)
- [OneDrive 2026 Guide](https://www.geeky-gadgets.com/onedrive-guide-2026/)
- [OneDrive on Mac Liquid Glass Design](https://redmondmag.com/blogs/redmond-dispatch/2026/02/onedrive-on-mac-introduces-liquid-glass-design.aspx)

**Comparison & Analysis:**
- [Best Cloud Storage With Sync 2026 (Cloudwards)](https://www.cloudwards.net/best-cloud-storage-with-sync/)
- [Enterprise File Sync Buyer's Guide (Computerworld)](https://www.computerworld.com/article/3520801/buyers-guide-enterprise-file-sync-and-sharing-services.html)
- [Cloud Service Comparison (Eylenburg)](https://eylenburg.github.io/cloud_comparison.htm)

**Competitive Analysis:**
- Internal: `.planning/codebase/COMPETITIVE_LANDSCAPE.md` (ExpanDrive, Mountain Duck, rclone analysis)
- [ExpanDrive](https://www.expandrive.com/)
- [Mountain Duck](https://mountainduck.io/)
