@testable import DS3Lib
import XCTest

final class SyncAnchorHashTests: XCTestCase {
    // MARK: - Format regression fixtures (Phase 16 Plan 05)

    //
    // The following hex values were captured against the pre-swap CryptoKit
    // `SHA256.hash(...)` implementation and lock the wire-format of
    // `NSFileProviderSyncAnchor` across the CommonCrypto swap. If any of these
    // assertions fail post-swap, the system would silently force a full
    // re-enumeration on every drive on first launch after upgrade (T-16-05-01).
    //
    // Both CryptoKit's SHA256 and CommonCrypto's CC_SHA256 wrap Apple
    // CoreCrypto's FIPS 180-4 SHA-256 primitive (Assumption A6) so the byte
    // output MUST be identical for identical inputs.

    private static func hex(_ data: Data) -> String {
        // Anchor bytes are always 7-bit ASCII (`v1:` + hex digits) so the
        // failable initializer never returns nil for valid inputs.
        String(bytes: data, encoding: .utf8) ?? ""
    }

    func testFixture_EmptyInputProducesKnownSHA256() {
        let bytes = SyncAnchorHash.compute(over: [])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "Empty input must hash to SHA256(\"\") with v1: prefix — locks wire format across CryptoKit→CommonCrypto swap"
        )
    }

    func testFixture_PlanExampleProducesPreSwapSHA256() {
        let pairs: [(String, String?)] = [("foo.txt", "abc123"), ("bar.txt", "def456")]
        let bytes = SyncAnchorHash.compute(over: pairs)
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:a06b1dd592aea7aaf1c89f8fa356bd3a303c09f43dda2d2932a13da7b228b9ca",
            "Plan-spec fixture: captured from pre-swap CryptoKit SHA256(sorted(bar.txt\\tdef456\\nfoo.txt\\tabc123))"
        )
    }

    func testFixture_SingleEntryNilEtagPreSwapSHA256() {
        let bytes = SyncAnchorHash.compute(over: [("a", nil)])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:f3a1b852a7774425faa9e4fa1cd8f312f557bcb1a2cd22d256b241a802acba2a"
        )
    }

    func testFixture_SingleEntryNonEmptyEtagPreSwapSHA256() {
        let bytes = SyncAnchorHash.compute(over: [("a", "1")])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:3db57393fc6220a0a72df6f0a1cc6334f89dba77b18362119ff15ce4568b5762"
        )
    }

    func testFixture_UnicodeKeyAndEtagPreSwapSHA256() {
        // Captures the UTF-8 byte sequence of multi-byte Unicode flowing into SHA-256.
        let bytes = SyncAnchorHash.compute(over: [("café/ñ.txt", "etag-üñ")])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:5c0165b0f3e9017818722e8c462dee6f4756be87fe0abc2e875757cfe6a7c3d5"
        )
    }

    func testFixture_LongKeyPreSwapSHA256() {
        // 1 KiB key — exercises CC_LONG cast boundary on the data length.
        let longKey = String(repeating: "x", count: 1024)
        let bytes = SyncAnchorHash.compute(over: [(longKey, "et")])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:5729e052b16952d3be43ad95e6f3ab28eaa041218b82d2ed593be05566a83db1"
        )
    }

    func testFixture_ThreeEntrySortedPreSwapSHA256() {
        let bytes = SyncAnchorHash.compute(over: [("a", "1"), ("b", "2"), ("c", "3")])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:f33d90c11641869a9dedf73d83d7cd5babee8b0a19369912449e4551a918112b"
        )
    }

    func testFixture_ConcurrentCallsAreReentrantAndStable() {
        // CC_SHA256 is reentrant — same input from many threads must produce
        // identical output (no shared mutable state in the helper).
        let pairs: [(String, String?)] = [("foo.txt", "abc123"), ("bar.txt", "def456")]
        let expected = "v1:a06b1dd592aea7aaf1c89f8fa356bd3a303c09f43dda2d2932a13da7b228b9ca"
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SyncAnchorHashTests.concurrent", attributes: .concurrent)
        let lock = NSLock()
        var collected: [String] = []
        for _ in 0 ..< 32 {
            group.enter()
            queue.async {
                let out = Self.hex(SyncAnchorHash.compute(over: pairs))
                lock.lock()
                collected.append(out)
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(collected.count, 32)
        for out in collected {
            XCTAssertEqual(out, expected)
        }
    }

    func testFixture_WorkingSetWithoutStampPreSwapSHA256() {
        let entry = SyncAnchorHash.WorkingSetEntry(key: "a", etag: "1", thumbnailReadyAt: nil)
        let bytes = SyncAnchorHash.computeWorkingSet(over: [entry])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:21d072d4dec3af8937b13ed77a0ea8efecded58635a23208c8e0456aa2926602",
            "WorkingSet anchor with nil thumbnailReadyAt — locks IEXT-153 wire format"
        )
    }

    func testFixture_WorkingSetWithStampPreSwapSHA256() {
        let stamp = Date(timeIntervalSince1970: 1_234_567_890.5)
        let entry = SyncAnchorHash.WorkingSetEntry(key: "a", etag: "1", thumbnailReadyAt: stamp)
        let bytes = SyncAnchorHash.computeWorkingSet(over: [entry])
        XCTAssertEqual(
            Self.hex(bytes),
            "v1:0d004e8fd73fdd8e2ace7471ab15c750720d0d4e6df79d12903b555c12dc6d5f",
            "WorkingSet anchor with non-nil thumbnailReadyAt — locks IEXT-153 wire format"
        )
    }

    // MARK: - Behavioural invariants

    func testFormatPrefixIsV1() {
        let bytes = SyncAnchorHash.compute(over: [("a", "1")])
        let asString = String(bytes: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.hasPrefix("v1:"), "anchor must be 'v1:' prefixed for forward compat")
    }

    func testEmptyInputProducesStableAnchor() {
        let first = SyncAnchorHash.compute(over: [])
        let second = SyncAnchorHash.compute(over: [])
        XCTAssertEqual(first, second)
    }

    func testOrderInsensitive() {
        let ascending = SyncAnchorHash.compute(over: [("a", "1"), ("b", "2"), ("c", "3")])
        let descending = SyncAnchorHash.compute(over: [("c", "3"), ("b", "2"), ("a", "1")])
        XCTAssertEqual(ascending, descending, "anchor must be order-insensitive")
    }

    func testEtagChangeChangesAnchor() {
        let original = SyncAnchorHash.compute(over: [("a", "1")])
        let modified = SyncAnchorHash.compute(over: [("a", "2")])
        XCTAssertNotEqual(original, modified)
    }

    func testKeyAddOrRemovalChangesAnchor() {
        let two = SyncAnchorHash.compute(over: [("a", "1"), ("b", "2")])
        let one = SyncAnchorHash.compute(over: [("a", "1")])
        XCTAssertNotEqual(two, one)
    }

    func testNilEtagAndEmptyEtagHashIdentically() {
        // Nil etag becomes "" via the compute formatter; an actual ""
        // remote etag is still distinguishable from a different etag value.
        // The anchor merely needs to be deterministic and stable; this test
        // pins that contract for future-proofing.
        let nilSide = SyncAnchorHash.compute(over: [("a", nil)])
        let emptySide = SyncAnchorHash.compute(over: [("a", "")])
        XCTAssertEqual(nilSide, emptySide, "documented: nil and \"\" hash identically (both serialise to empty)")
    }
}
