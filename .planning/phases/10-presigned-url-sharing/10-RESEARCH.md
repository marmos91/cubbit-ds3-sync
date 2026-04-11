# Phase 10: Presigned URL Sharing - Research

**Researched:** 2026-04-08
**Domain:** S3 presigned URLs, File Provider custom actions, UNUserNotificationCenter
**Confidence:** HIGH

## Summary

This phase adds three right-click custom actions to the File Provider extension that generate SigV4 presigned GET URLs for selected files and copy them to the clipboard. The existing codebase already has a working custom action (`copyS3URL`) that serves as a direct template -- the new actions follow the identical pattern but call Soto's `signURL` instead of constructing a plain `s3://` URI.

The key technical components are: (1) Soto v6's `AWSService.signURL(url:httpMethod:headers:expires:)` which is async but performs only CPU-bound signing (no network), (2) constructing the correct path-style object URL from the endpoint + bucket + key, (3) posting `UNUserNotificationCenter` notifications from the extension process, and (4) three new `NSExtensionFileProviderActions` entries in Info.plist with folder-exclusion activation rules.

**Primary recommendation:** Mirror the existing `copyS3URL` action pattern exactly, adding a `DS3S3Client+Presign.swift` extension for the signing logic and a notification helper for user feedback.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- D-01: Three top-level right-click actions: `Copy presigned URL (1 hour)` / `(1 day)` / `(7 days)`. Max expiry 7 days (SigV4 limit), hard-coded.
- D-02: Ship on both macOS and iOS in the same PR. Both platforms share `FileProviderExtension+CustomActions.swift`.
- D-03: Post `UNUserNotification` on success with expiry in body. Error notification on failure. Silently no-op on denied authorization.
- D-04: All logic in extension process. Mirror existing `copyS3URL` pattern. Single item = one URL; multiple items = newline-joined. Only `NSFileProviderError` / `NSCocoaError` domains.
- D-05: Activation rule excludes folders (`kMDItemContentTypeTree != 'public.folder'`).
- D-06: New `DS3S3Client+Presign.swift` with `presignedGetURL(bucket:key:expiresIn:)`. Validates `expiresIn` in `(0, 604800]`.

### Claude's Discretion
- Notification helper implementation details (DateComponentsFormatter vs hardcoded strings)
- Task group concurrency pattern for multi-select
- Test structure and naming conventions

### Deferred Ideas (OUT OF SCOPE)
- Configurable expiry beyond 3 presets
- Web console-style link dialog with QR / shortened URL
- Read-write presigned URLs
- Tray-menu version of the action
- Anonymous listing presigned URLs for folders
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SHARE-01 | Right-click any file in Finder/Files.app to copy a time-limited presigned S3 URL with 3 duration presets (1h/1d/7d) and system notification confirming expiry | Soto signURL API verified in source, existing custom action pattern documented, UNUserNotificationCenter feasibility confirmed, Info.plist activation rule syntax verified |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Soto (SotoS3 + SotoCore) | v6 (in-tree) | S3 presigned URL generation via `signURL` | Already the project's S3 client; `signURL` is built into `AWSService` [VERIFIED: source at soto-core/Sources/SotoCore/AWSService+async.swift:30-38] |
| FileProvider framework | macOS 15+ / iOS 17+ | Custom action registration and dispatch | Already in use for copyS3URL, evictItem, restoreFromTrash [VERIFIED: DS3DriveProvider/FileProviderExtension+CustomActions.swift] |
| UserNotifications framework | macOS 15+ / iOS 17+ | Post success/error notifications from extension | Available in both app extensions and main apps [VERIFIED: Apple docs] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| DS3Lib (local package) | in-tree | Shared types, SystemService clipboard abstraction | Always -- clipboard write goes through `SystemService.copyToClipboard()` [VERIFIED: DS3Lib/Sources/DS3Lib/Platform/SystemService.swift] |

No new dependencies required. Everything needed is already in the project.

## Architecture Patterns

### Recommended Project Structure
```
DS3Lib/Sources/DS3Lib/
├── DS3S3Client+Presign.swift        # New: presignedGetURL method
DS3DriveProvider/
├── FileProviderExtension+CustomActions.swift  # Modified: 3 new action cases
├── Info.plist                                  # Modified: 3 new action entries
├── PresignNotificationHelper.swift            # New: UNUserNotification wrapper
DS3Lib/Tests/DS3LibTests/
├── DS3S3ClientPresignTests.swift              # New: unit tests for URL construction
```

### Pattern 1: Soto signURL API
**What:** `AWSService.signURL(url:httpMethod:headers:expires:)` generates a SigV4-signed URL. It is async but performs no network I/O -- it only needs credentials (already loaded in the signer) and CPU for HMAC computation. [VERIFIED: soto-core/Sources/SotoCore/AWSClient+async.swift:360-378]
**When to use:** Every presigned URL generation call.
**Example:**
```swift
// Source: DS3Lib/.build/checkouts/soto-core/Sources/SotoCore/AWSService+async.swift:30-38
let signedURL = try await s3.signURL(
    url: objectURL,          // e.g. https://s3.cubbit.eu/mybucket/path/to/file.txt
    httpMethod: .GET,
    expires: .seconds(3600)  // TimeAmount from NIOCore
)
```

**Key detail:** The `expires` parameter is `NIOCore.TimeAmount`. Use `.seconds(Int64)`, `.hours(Int64)`, etc. Maximum is 604800 seconds (7 days) per SigV4 spec. [VERIFIED: signer source shows `expires.nanoseconds / 1_000_000_000` conversion at SotoSignerV4/signer.swift:159]

### Pattern 2: Object URL Construction for Custom Endpoints
**What:** Soto's `signURL` takes a `URL` parameter -- you must construct the correct S3 object URL yourself. With a custom endpoint like `https://s3.cubbit.eu`, Cubbit DS3 uses **path-style** URLs: `https://s3.cubbit.eu/{bucket}/{key}`. [VERIFIED: DS3S3Client creates S3 with custom endpoint at DS3S3Client.swift:202, no `s3ForceVirtualHost` option is set]
**Example:**
```swift
// Build the object URL from endpoint + bucket + key
// endpoint = "https://s3.cubbit.eu" (from FileProviderExtension.endpoint)
// bucket = drive.syncAnchor.bucket.name
// key = itemIdentifier.rawValue (already the full S3 key)
guard let objectURL = URL(string: "\(endpoint)/\(bucket)/\(key)") else {
    throw NSFileProviderError(.cannotSynchronize)
}
```

**Critical: URL-encode the key.** S3 keys can contain spaces and special characters. Use `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` on the key before constructing the URL. [ASSUMED]

### Pattern 3: Custom Action Dispatch (existing pattern)
**What:** `performAction(identifier:onItemsWithIdentifiers:completionHandler:)` switches on `actionIdentifier.rawValue`, filters system containers, processes items, calls `completionHandler(nil)` on success or `completionHandler(error)` on failure.
**Source:** `DS3DriveProvider/FileProviderExtension+CustomActions.swift:18-70`
```swift
case CustomActionIdentifier.copyPresignedURL1h:
    let bucket = drive.syncAnchor.bucket.name
    let validIdentifiers = itemIdentifiers.filter { !$0.isSystemContainer }
    
    if validIdentifiers.isEmpty {
        completionHandler(NSFileProviderError(.noSuchItem) as NSError)
        return progress
    }
    
    let boxedCb = UncheckedBox(value: completionHandler)
    Task {
        do {
            var urls: [String] = []
            for id in validIdentifiers {
                let url = try await self.s3Client!.presignedGetURL(
                    bucket: bucket, key: id.rawValue, expiresIn: 3600
                )
                urls.append(url.absoluteString)
            }
            self.systemService.copyToClipboard(urls.joined(separator: "\n"))
            // post notification
            boxedCb.value(nil)
        } catch {
            boxedCb.value(NSFileProviderError(.cannotSynchronize) as NSError)
        }
    }
```

### Pattern 4: UNUserNotificationCenter from Extension
**What:** File Provider extensions CAN post local notifications using `UNUserNotificationCenter`. The extension runs as its own process and has its own notification authorization status. Authorization must be requested lazily (first use) and silently degraded if denied.
**Example:**
```swift
import UserNotifications

func postPresignNotification(expiryLabel: String, isError: Bool = false) {
    let content = UNMutableNotificationContent()
    content.title = isError ? "Failed to copy link" : "Link copied"
    content.body = isError ? "Could not generate presigned URL" : "Expires in \(expiryLabel)"
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil  // deliver immediately
    )
    
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
        guard granted else { return }  // silent no-op per D-03
        center.add(request)
    }
}
```
[ASSUMED: Extension can call `requestAuthorization` -- may share authorization with the host app via App Group. Needs runtime validation.]

### Anti-Patterns to Avoid
- **Custom error domains:** Never return errors outside `NSFileProviderErrorDomain` or `NSCocoaErrorDomain` to `completionHandler`. The system silently swallows them. [VERIFIED: CLAUDE.md + project memory]
- **Network calls in signURL:** Don't confuse `signURL` with actual S3 requests. `signURL` is pure computation -- no timeout, no retry needed. [VERIFIED: source inspection]
- **Virtual-hosted URLs with custom endpoints:** Don't construct `https://{bucket}.s3.cubbit.eu/{key}`. Cubbit uses path-style. [VERIFIED: existing client construction]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SigV4 presigned URL | Manual HMAC signing | `s3.signURL(url:httpMethod:expires:)` | SigV4 has complex canonical request construction, region scoping, credential derivation [VERIFIED: soto-core signer source] |
| Cross-platform clipboard | `#if os()` conditionals | `self.systemService.copyToClipboard()` | Already abstracted; NSPasteboard (macOS) and UIPasteboard (iOS) handled [VERIFIED: SystemService+macOS.swift, SystemService+iOS.swift] |
| Duration formatting | Manual string building | `DateComponentsFormatter` with `.abbreviated` style | Handles pluralization, localization automatically |

**Key insight:** The entire presigning stack exists -- Soto's signer, the clipboard abstraction, the custom action dispatch. This phase is composition, not invention.

## Common Pitfalls

### Pitfall 1: S3 Key URL Encoding
**What goes wrong:** S3 keys with spaces, unicode, or special characters produce invalid URLs when naively concatenated.
**Why it happens:** `URL(string:)` returns nil for strings with unescaped spaces.
**How to avoid:** Percent-encode the key component with `.urlPathAllowed` before building the URL. The existing `DS3S3Client.decodeS3Key` handles the reverse direction. [VERIFIED: DS3S3Client.swift:346-352]
**Warning signs:** `signURL` throws `AWSClient.ClientError.invalidURL` or `URL(string:)` returns nil.

### Pitfall 2: TimeAmount vs Seconds Confusion
**What goes wrong:** Passing raw seconds to `TimeAmount` constructor instead of using `.seconds()`.
**Why it happens:** `TimeAmount` stores nanoseconds internally. `TimeAmount(3600)` = 3600 nanoseconds, not seconds.
**How to avoid:** Always use `.seconds(3600)`, `.hours(1)`, or `.days(7)`. [VERIFIED: soto-core signer uses `expires.nanoseconds / 1_000_000_000`]
**Warning signs:** Presigned URLs expire immediately or have absurdly short lifetimes.

### Pitfall 3: Notification Authorization in Extension
**What goes wrong:** Notifications never appear because authorization was never requested in the extension process.
**Why it happens:** Each process (main app, extension) may have independent notification authorization state. The extension process may not share the main app's authorization.
**How to avoid:** Call `requestAuthorization` in the extension before posting. Cache the result to avoid repeated prompts. Degrade silently if denied (per D-03). [ASSUMED -- needs runtime verification]
**Warning signs:** `UNUserNotificationCenter.add()` succeeds but nothing appears.

### Pitfall 4: NSPredicate Syntax in Activation Rules
**What goes wrong:** Activation rule doesn't filter correctly, showing presign actions on folders.
**Why it happens:** NSPredicate syntax for MDQuery is different from standard NSPredicate.
**How to avoid:** Use `kMDItemContentTypeTree != 'public.folder'` -- this is valid NSPredicate syntax for File Provider activation rules. The existing actions use `TRUEPREDICATE`. [ASSUMED -- Apple documentation is sparse on this; may need `NONE kMDItemContentTypeTree UTI-CONFORMS-TO "public.folder"` syntax instead]
**Warning signs:** Actions appear on folder items in Finder/Files.app context menu.

### Pitfall 5: UncheckedBox for Completion Handler
**What goes wrong:** Swift 6 concurrency rejects capturing `@escaping (Error?) -> Void` in a `Task`.
**Why it happens:** The completion handler is not `Sendable`.
**How to avoid:** Wrap in `UncheckedBox` as the existing code does. [VERIFIED: FileProviderExtension.swift:8-11, used throughout custom actions]
**Warning signs:** Compiler error about capturing non-Sendable closure.

## Code Examples

### DS3S3Client+Presign.swift
```swift
// New file: DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift
import Foundation
import SotoS3

public enum PresignError: Error {
    case invalidPresignExpiry
    case invalidObjectURL
}

public extension DS3S3Client {
    /// Generates a presigned GET URL for an S3 object.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The S3 object key
    ///   - expiresIn: Seconds until expiry, must be in (0, 604800]
    /// - Returns: A signed URL that allows unauthenticated GET for the duration
    func presignedGetURL(bucket: String, key: String, expiresIn: Int) async throws -> URL {
        guard expiresIn > 0, expiresIn <= 604_800 else {
            throw PresignError.invalidPresignExpiry
        }
        
        // Build path-style URL: endpoint/bucket/key
        guard let endpoint = s3.config.endpoint else {
            throw PresignError.invalidObjectURL
        }
        
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let objectURL = URL(string: "\(endpoint)/\(bucket)/\(encodedKey)") else {
            throw PresignError.invalidObjectURL
        }
        
        return try await s3.signURL(
            url: objectURL,
            httpMethod: .GET,
            expires: .seconds(Int64(expiresIn))
        )
    }
}
```

### Info.plist Action Entry
```xml
<!-- One of three entries; repeat with different identifier/name/expiry -->
<dict>
    <key>NSExtensionFileProviderActionIdentifier</key>
    <string>io.cubbit.DS3Drive.DS3DriveProvider.action.presignURL1h</string>
    <key>NSExtensionFileProviderActionName</key>
    <string>Copy presigned URL (1 hour)</string>
    <key>NSExtensionFileProviderActionActivationRule</key>
    <string>kMDItemContentTypeTree != 'public.folder'</string>
</dict>
```

### Custom Action Handler (in switch statement)
```swift
// Source: mirrors existing copyS3URL pattern at CustomActions.swift:31-46
case CustomActionIdentifier.presignURL1h,
     CustomActionIdentifier.presignURL1d,
     CustomActionIdentifier.presignURL7d:
    
    let expiresIn: Int
    let label: String
    switch actionIdentifier.rawValue {
    case CustomActionIdentifier.presignURL1h: expiresIn = 3_600; label = "1 hour"
    case CustomActionIdentifier.presignURL1d: expiresIn = 86_400; label = "1 day"
    case CustomActionIdentifier.presignURL7d: expiresIn = 604_800; label = "7 days"
    default: fatalError("unreachable")
    }
    
    let bucket = drive.syncAnchor.bucket.name
    let validIdentifiers = itemIdentifiers.filter { !$0.isSystemContainer }
    guard !validIdentifiers.isEmpty else {
        completionHandler(NSFileProviderError(.noSuchItem) as NSError)
        return progress
    }
    
    guard let s3Client = self.s3Client else {
        completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
        return progress
    }
    
    let boxedCb = UncheckedBox(value: completionHandler)
    Task {
        do {
            var urls: [String] = []
            for id in validIdentifiers {
                let url = try await s3Client.presignedGetURL(
                    bucket: bucket, key: id.rawValue, expiresIn: expiresIn
                )
                urls.append(url.absoluteString)
                progress.completedUnitCount += 1
            }
            self.systemService.copyToClipboard(urls.joined(separator: "\n"))
            self.logger.info("Copied \(urls.count) presigned URL(s) to clipboard (expires: \(label))")
            PresignNotificationHelper.postSuccess(expiryLabel: label)
            boxedCb.value(nil)
        } catch {
            self.logger.error("Presign URL failed: \(error.localizedDescription, privacy: .public)")
            PresignNotificationHelper.postError()
            boxedCb.value(NSFileProviderError(.cannotSynchronize) as NSError)
        }
    }
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual SigV4 construction | Soto `signURL` built-in | Soto v6 | No hand-rolling needed |
| NSUserNotification (macOS) | UNUserNotificationCenter (cross-platform) | macOS 10.14 / iOS 10 | Single API for both platforms |

**Deprecated/outdated:**
- `NSUserNotification`: Deprecated since macOS 10.14. Use `UNUserNotificationCenter` exclusively.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | S3 key percent-encoding with `.urlPathAllowed` is sufficient for all valid S3 keys | Pitfall 1, Code Examples | Presigned URLs for files with unusual characters (e.g., `+`, `#`) may be malformed. Mitigation: test with special-char filenames. |
| A2 | File Provider extension process can request UNUserNotification authorization independently | Pitfall 3, Pattern 4 | Notifications silently fail. Low risk: clipboard is primary feedback (D-03). |
| A3 | `kMDItemContentTypeTree != 'public.folder'` is valid NSPredicate syntax for activation rules | Pitfall 4, Info.plist | Actions appear on folders (cosmetic issue only -- presigning a folder GET returns an XML listing page). Alternative syntax may be needed. |
| A4 | Soto's `s3.config.endpoint` property is accessible and returns the custom endpoint string | Code Examples | `PresignError.invalidObjectURL` thrown. Mitigation: use `self.endpoint` from FileProviderExtension instead, passing it as parameter. |

## Open Questions

1. **Activation rule NSPredicate syntax for folder exclusion**
   - What we know: Apple documentation on `NSExtensionFileProviderActionActivationRule` is minimal. `TRUEPREDICATE` works (used by existing actions). MDQuery predicate format should work.
   - What's unclear: Whether `kMDItemContentTypeTree != 'public.folder'` is the exact correct syntax, or if it needs `NONE kMDItemContentTypeTree UTI-CONFORMS-TO "public.folder"`.
   - Recommendation: Start with `kMDItemContentTypeTree != 'public.folder'`. Test on both platforms. If folders still show actions, try alternative syntax. Worst case, handle folders gracefully in code (skip with no error).

2. **UNUserNotification authorization flow in extension**
   - What we know: Extensions run as separate processes. `UNUserNotificationCenter.current()` works in app extensions.
   - What's unclear: Whether the extension shares notification authorization with the host app, or needs independent authorization.
   - Recommendation: Call `requestAuthorization(options: [.alert])` before first notification. Cache result. Silent no-op if denied (per D-03). Test on real device.

3. **Soto config.endpoint accessibility**
   - What we know: `S3` is initialized with `endpoint: String?` parameter. The `config` property is public on `AWSService`.
   - What's unclear: Whether `s3.config.endpoint` is a stored property accessible after init.
   - Recommendation: If `s3.config.endpoint` is not accessible, pass the endpoint string from `FileProviderExtension.endpoint` (which stores `account.endpointGateway`) as a parameter to the presign method.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built-in) |
| Config file | DS3Lib/Package.swift (test target: DS3LibTests) |
| Quick run command | `cd DS3Lib && swift test --filter DS3S3ClientPresignTests` |
| Full suite command | `cd DS3Lib && swift test` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SHARE-01a | presignedGetURL returns valid URL with SigV4 query params | unit | `cd DS3Lib && swift test --filter DS3S3ClientPresignTests/testPresignedURLContainsSigV4Params` | No -- Wave 0 |
| SHARE-01b | presignedGetURL rejects expiresIn <= 0 or > 604800 | unit | `cd DS3Lib && swift test --filter DS3S3ClientPresignTests/testInvalidExpiry` | No -- Wave 0 |
| SHARE-01c | URL correctly encodes keys with special characters | unit | `cd DS3Lib && swift test --filter DS3S3ClientPresignTests/testSpecialCharacterKeys` | No -- Wave 0 |
| SHARE-01d | Presigned URL works against live Cubbit endpoint | integration | `cd DS3Lib && swift test --filter DS3S3ClientIntegrationTests/testPresignedURL` | No -- Wave 0 |
| SHARE-01e | Custom action dispatches correctly for each duration | manual-only | Build + right-click in Finder/Files.app | N/A |
| SHARE-01f | Notification appears on success | manual-only | Build + trigger action, observe notification | N/A |

### Sampling Rate
- **Per task commit:** `cd DS3Lib && swift test --filter DS3S3ClientPresignTests`
- **Per wave merge:** `cd DS3Lib && swift test`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/DS3S3ClientPresignTests.swift` -- unit tests for presign URL construction and validation
- [ ] `DS3Lib/Tests/DS3LibTests/Integration/DS3S3ClientIntegrationTests.swift` -- add presign integration test case

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | N/A (presigned URLs are intentionally unauthenticated access) |
| V3 Session Management | no | N/A |
| V4 Access Control | yes | SigV4 time-limited expiry (max 7 days); GET-only (no write) |
| V5 Input Validation | yes | `expiresIn` validated in `(0, 604800]`; key percent-encoded |
| V6 Cryptography | yes | Soto's SigV4 signer handles HMAC-SHA256 -- never hand-roll |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| URL shared beyond intended audience | Information Disclosure | Time-limited expiry (max 7 days); GET-only; no listing |
| Expiry bypass via clock skew | Tampering | Server-side enforcement by S3 (Cubbit validates `X-Amz-Date` + `X-Amz-Expires`) |
| Key injection in URL | Tampering | Percent-encode key; `URL(string:)` nil-check |

## Sources

### Primary (HIGH confidence)
- Soto v6 source code (in-tree at `DS3Lib/.build/checkouts/soto-core/`) -- signURL API signature, signer implementation, TimeAmount handling
- Project source code -- `FileProviderExtension+CustomActions.swift`, `DS3S3Client.swift`, `SystemService*.swift`, `Info.plist`, `DS3Client.swift`

### Secondary (MEDIUM confidence)
- Apple FileProvider documentation -- NSExtensionFileProviderActions, activation rules
- Apple UserNotifications documentation -- UNUserNotificationCenter in app extensions

### Tertiary (LOW confidence)
- Activation rule NSPredicate syntax for `kMDItemContentTypeTree` -- sparse Apple documentation [A3]
- UNUserNotificationCenter authorization sharing between extension and host app [A2]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in-tree, APIs verified in source
- Architecture: HIGH -- direct extension of existing pattern (copyS3URL)
- Pitfalls: MEDIUM -- activation rule syntax and notification authorization need runtime validation
- Security: HIGH -- SigV4 signing delegated to Soto, time limits enforced server-side

**Research date:** 2026-04-08
**Valid until:** 2026-05-08 (stable domain, no expected API changes)
