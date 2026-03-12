# Codebase Concerns

**Analysis Date:** 2026-03-11

## Tech Debt

**Incomplete error handling and logging patterns:**
- Issue: Multiple S3 API responses are intentionally ignored without checking for errors or side effects
- Files: `Provider/S3Lib.swift` (lines 206, 333, 631)
- Impact: DeleteObject, CopyObject, and CompleteMultipartUpload responses are discarded. If the server indicates failure in the response metadata, the code won't detect it
- Fix approach: Audit S3 API responses for critical metadata (e.g., version IDs, etags), validate them in assertions or logs, or explicitly handle server-side failures

**Hardcoded values in UI:**
- Issue: Multiple UI components contain TODO comments about hardcoded display values
- Files: `CubbitDS3Sync/Views/Sync/SyncAnchorSelection/Views/SyncAnchorSelectorView.swift` (line 52), `SyncAnchorSelectionView.swift` (line 52), `BucketSelectionSidebarView.swift` (line 37), `BucketSelectionColumn.swift` (line 26)
- Impact: These hardcoded values may not properly reflect actual UI requirements or responsive design principles
- Fix approach: Extract values to constants or configuration; implement proper responsive sizing logic

**Generic/weak error mapping:**
- Issue: Error conversion from S3 errors to NSError is minimal
- Files: `Provider/FileProviderExtension+Errors.swift` (lines 38-42)
- Impact: S3ErrorType is converted to generic NSFileReadUnknownError without preserving error codes or details, making debugging difficult
- Fix approach: Implement richer error mapping that preserves S3 error codes and context

## Known Bugs

**Critical: copyFolder returns early, skipping remaining items:**
- Symptoms: When copying a folder with multiple items, only the first item is copied; subsequent items are never processed
- Files: `Provider/S3Lib.swift` (line 374)
- Trigger: Call copyFolder() with a folder containing multiple objects
- Details: The while loop on line 368 has an early `return` on line 374 instead of `continue`, causing the function to exit after processing the first item. This breaks recursive folder copying entirely
- Workaround: None - folder copy operations fail silently
- Priority: Critical

**Move operation sometimes fails with NoSuchKey:**
- Symptoms: File move operations occasionally fail with S3 NoSuchKey error
- Files: `Provider/FileProviderExtension.swift` (line 362)
- Trigger: Unknown - appears to be intermittent
- Workaround: Retry the operation
- Context: Code comment indicates this is a known intermittent issue but root cause is unidentified

**Symbolic link upload is silently rejected:**
- Symptoms: Users attempting to upload symbolic links get a "Feature not supported" error
- Files: `Provider/FileProviderExtension.swift` (line 199)
- Trigger: Upload symbolic link via Finder
- Workaround: Use actual files instead

## Security Considerations

**Missing 2FA validation strength:**
- Risk: 2FA code validation exists but error messaging may leak information about valid vs invalid users
- Files: `DS3Lib/DS3Authentication.swift` (lines 6-49)
- Current mitigation: Server-side validation is primary defense
- Recommendations: Ensure consistent error messages for missing 2FA regardless of authentication state; implement rate limiting on 2FA attempts

**Credential handling in App Group container:**
- Risk: API keys and authentication tokens are stored in App Group shared container accessible to all app processes
- Files: `DS3Lib/SharedData/` directory (all files)
- Current mitigation: App Group is restricted to the app bundle; relies on macOS sandbox
- Recommendations: Consider encrypting sensitive data at rest using Keychain instead of plain JSON files; audit all file permissions on shared container

**Challenge-response auth relies on proper key storage:**
- Risk: If private keys are compromised, authentication can be forged
- Files: `DS3Lib/DS3Authentication.swift` (curve25519 challenge-response implementation)
- Current mitigation: Relies on system keychain for private key storage
- Recommendations: Verify private keys are always stored in Keychain, never persisted to disk as plaintext

## Performance Bottlenecks

**No pagination limit on recursive folder deletion:**
- Problem: Deleting large folders requires multiple list operations but no optimization for hierarchical deletion
- Files: `Provider/S3Lib.swift` (deleteFolder method, lines 213-249)
- Cause: Recursively lists all objects before deleting; no batching or server-side operations
- Improvement path: Implement delete-multiple endpoint if available; use S3 delete markers; consider server-side delete-with-prefix

**File provider extension initialization loads all metadata at startup:**
- Problem: On extension init, all drive, API key, and account data must be loaded from App Group; no caching strategy
- Files: `Provider/FileProviderExtension.swift` (lines 25-60)
- Cause: Force-unwrapped optionals indicate synchronous loading with no fallback
- Improvement path: Lazy-load drive metadata; cache in memory with invalidation strategy; handle missing data gracefully

**Multipart upload part size is not configurable:**
- Problem: Fixed 5MB part size may not be optimal for all network conditions or file types
- Files: `Provider/FileProviderExtension.swift` (line 227), `Provider/S3Lib.swift` (references to DefaultSettings.S3.multipartUploadPartSize)
- Cause: Hardcoded in DefaultSettings
- Improvement path: Make part size configurable; auto-adjust based on available bandwidth or file size

## Fragile Areas

**FileProviderExtension initialization with force-unwrapped optionals:**
- Files: `Provider/FileProviderExtension.swift` (lines 32-53)
- Why fragile: Multiple force-unwraps (!, as!) on critical initialization paths. If SharedData fails to load, the entire extension crashes
- Safe modification: Replace force-unwraps with proper error handling; return early from init if any required data fails to load
- Test coverage: No test files found in repository - extension behavior is untested

**S3Enumerator relies on stale sync anchor:**
- Files: `Provider/S3Enumerator.swift` (line 17)
- Why fragile: `SharedData.default().loadSyncAnchorOrCreate()` is called once at init time, never refreshed; if anchor changes in parent app, enumerator is out of sync
- Safe modification: Refresh anchor from parent domain on each enumeration cycle; use passed-in drive parameter instead of cached anchor
- Test coverage: None

**EnumeratorError typo in enum name:**
- Files: `Provider/S3Enumerator.swift` (line 7)
- Why fragile: Enum is named `unsopported` (should be `unsupported`) but is used in multiple places; misspelling propagates
- Impact: Minor - code works but violates conventions
- Safe modification: Rename enum case to `unsupported`; update all call sites

**Print statement in production code:**
- Files: `DS3Lib/DS3DriveManager.swift` (line 190)
- Why fragile: Uses `print()` instead of logger; bypasses log level filtering and structured logging
- Safe modification: Replace with self.logger.error()

## Scaling Limits

**No limit on number of drives per account:**
- Current capacity: Unbounded
- Limit: Finder may become unresponsive with 100+ drives; each drive registers a separate file provider domain
- Scaling path: Implement drive grouping; use single domain with virtual folders; add UI pagination

**Continuation token pagination not tested with large buckets:**
- Current capacity: Unknown - depends on S3 implementation of continuationToken
- Limit: If bucket exceeds list batch size threshold without proper pagination, items may be lost
- Scaling path: Implement integration tests with >10,000 objects; validate continuation token handling

**Shared container file I/O is synchronous:**
- Current capacity: Single-threaded JSON serialization/deserialization
- Limit: File writes block FileProvider extension threads; slow disk or large JSON files cause UI freezes
- Scaling path: Implement async file I/O; use structured codable formats (Protocol Buffers); add write batching

## Dependencies at Risk

**Soto v6 (SotoS3) - No direct version lock verification:**
- Risk: Swift Package Manager dependency may receive breaking updates; Soto is actively maintained but API can change
- Impact: Swift version compatibility issues; S3 API changes could require code updates
- Current strategy: Uses Soto v6 explicitly
- Recommendations: Monitor Soto releases; test major version upgrades before deploying; consider pinning to specific patch version if stability is critical

**Atomics usage limited to single flag:**
- Risk: `swift-atomics` is used only for shutdown flag; if future code adds concurrent state, atomics usage patterns may be inconsistent
- Impact: Race conditions if concurrent data access is introduced
- Recommendations: Audit all shared state between FileProvider extension and main app; prefer Actor types over manual atomics for new concurrent code

## Missing Critical Features

**No trash/recycle functionality:**
- Problem: Trash container is explicitly disabled (line 87-89 in FileProviderExtension.swift); deleted files are permanently removed
- Blocks: Users cannot recover accidentally deleted files via Finder trash
- Impact: High-risk for data loss

**No symlink/alias support:**
- Problem: Symbolic links and alias files are explicitly rejected during upload and rename
- Blocks: Users cannot sync folder hierarchies with symlinks
- Impact: Medium - limits use cases for developers using symlink-heavy workflows

**No pinning policy implementation:**
- Problem: All items use `.downloadLazily` policy; no smart caching or "pin for offline" feature
- Blocks: Users cannot choose which files to keep locally available
- Impact: Medium - battery and bandwidth drain on systems with large remote folders

**No versioning support:**
- Problem: Multiple TODOs for versioning indicate feature is incomplete (FileProviderExtension lines 272, 403)
- Blocks: Versioned buckets not supported; versioning metadata ignored
- Impact: Medium - cannot use Cubbit versioning features

**No thumbnail generation:**
- Problem: Thumbnails explicitly not implemented (line 5 in FileProviderExtension.swift)
- Blocks: Finder does not show previews for images/documents
- Impact: Low - mostly UX convenience

## Test Coverage Gaps

**No unit tests found in repository:**
- What's not tested: All critical paths - authentication, S3 operations, file provider extension lifecycle, folder operations
- Files: Entire codebase
- Risk: High - regressions can silently break core functionality
- Priority: Critical
- Current approach: Only GitHub Actions runs `xcodebuild analyze`; no functional test suite

**Integration tests missing:**
- What's not tested: FileProvider-to-S3 round-trip; concurrent upload/download; error recovery; large folder enumeration
- Risk: High
- Priority: High

**UI tests missing:**
- What's not tested: Login flow, drive setup wizard, preferences, tray menu state management
- Risk: Medium
- Priority: Medium

---

*Concerns audit: 2026-03-11*
