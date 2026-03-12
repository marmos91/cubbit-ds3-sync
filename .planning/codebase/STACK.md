# Technology Stack

**Analysis Date:** 2026-03-11

## Languages

**Primary:**
- Swift 5.0+ - App code, UI (SwiftUI), libraries, and File Provider extension

**Secondary:**
- Objective-C - Bridging for Foundation and system frameworks (implicit)

## Runtime

**Environment:**
- macOS 14.2+ (Monterey and later)
- iOS 17.2+ (secondary target support)

**Package Manager:**
- Swift Package Manager (SPM)
- Lockfile: `CubbitDS3Sync.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## Frameworks

**Core Frameworks:**
- **SwiftUI** - UI framework for main app views and tray menu
- **AppKit** - Menu bar tray application integration

**File System Integration:**
- **FileProvider** (`NSFileProviderReplicatedExtension`) - Integrates with Finder to present S3 buckets as native macOS drives

**Cryptography & Security:**
- **CryptoKit** - Elliptic curve cryptography for authentication (Curve25519)
- **Security.framework** - Certificate and keychain operations

**System Integration:**
- **UniformTypeIdentifiers** - File type identification
- **os.log** - Structured logging
- **Foundation** - Core APIs, networking, JSON encoding

**Testing:**
- None detected in project structure

**Build/Dev:**
- Xcode 15.0+
- Apple-native build system

## Key Dependencies

**Critical:**
- **Soto (SotoS3) v6.8.0** - AWS S3 API client library for Swift
  - Why it matters: Core dependency for all S3 operations (upload, download, delete, listing)
  - Located in: Main app and Provider extension targets
  - GitHub: `https://github.com/soto-project/soto`

**Infrastructure & Networking:**
- **async-http-client v1.20.1** - HTTP client for async/await networking
  - Transitive dependency of Soto
- **soto-core v6.5.2** - Core AWS service definitions and utilities
  - Provides AWS service protocol implementations
- **swift-nio v2.62.0** - Network I/O framework
  - Enables async networking primitives

**Collections & Concurrency:**
- **swift-collections v1.0.6** - Apple's high-performance collection types
- **swift-algorithms v1.2.0** - Algorithm implementations
- **swift-atomics v1.2.0** - Thread-safe atomic operations for File Provider extension
- **swift-numerics v1.0.2** - Numeric algorithms

**Protocol & Serialization:**
- **jmespath.swift v1.0.2** - JMESPath query support for AWS responses
- **swift-http-types v1.0.2** - HTTP semantics types

**Logging & Metrics:**
- **swift-log v1.5.3** - Structured logging (os.log bridge)
- **swift-metrics v2.4.1** - Metrics collection API

**TLS & Transport:**
- **swift-nio-ssl v2.25.0** - TLS/SSL support
- **swift-nio-http2 v1.29.0** - HTTP/2 protocol support
- **swift-nio-extras v1.20.0** - NIO utilities
- **swift-nio-transport-services v1.20.0** - macOS transport services

## Configuration

**Environment:**
- **Xcode project settings** - `CubbitDS3Sync.xcodeproj/project.pbxproj`
- **App Groups** - `group.io.cubbit.CubbitDS3Sync` (shared between main app and extension)
- **Bundle Identifiers:**
  - Main app: `io.cubbit.CubbitDS3Sync`
  - File Provider extension: `io.cubbit.CubbitDS3Sync.FileProvider`

**Build Configuration:**
- **Deployment target:** macOS 14.2
- **Build system:** Xcode native
- **Versioning:** `MARKETING_VERSION = 1.4`

**Code Signing:**
- Requires manual provisioning profile configuration
- App Group matching required between main app and extension

## Platform Requirements

**Development:**
- macOS 14+ (Sonoma, Monterey, or later)
- Xcode 15.0 or later
- Valid Apple Developer account (for provisioning profiles and code signing)
- Git LFS for asset retrieval

**Production:**
- macOS 14.2 or later
- File Provider support (built-in on macOS 10.13+, required for replication)
- S3-compatible cloud storage backend (Cubbit DS3)

---

*Stack analysis: 2026-03-11*
