// DS3CoreFFISmokeTests verifies that the Rust-backed DS3CoreFFI XCFramework
// is correctly linked into DS3Lib and that the UniFFI-generated Swift surface
// (types + free functions) is reachable from the test target.
//
// Phase 16 Plan 01 (Task 3). See 16-FFI-AUDIT.md for the verified shapes of
// `Ds3SessionHandle` (`@unchecked Sendable`, Rust-named DS3SessionHandle ->
// Swift Ds3SessionHandle) and `Ds3Error` (`flat_error`, each variant
// `(message: String)`).
//
// These tests are intentionally cheap: no network, no Rust panics, no S3
// credentials. They prove the framework links and the Swift bindings compile.

import DS3CoreFFI
import XCTest

final class DS3CoreFFISmokeTests: XCTestCase {
    /// Compile-link check for the UniFFI session handle type.
    ///
    /// We don't instantiate it (that would do a full IAM round-trip). Just
    /// referencing `.self` proves the symbol resolves from the XCFramework
    /// and the Swift glue target re-exports it.
    func testCanReferenceSessionHandleType() {
        // Note: Rust `DS3SessionHandle` is exposed to Swift as `Ds3SessionHandle`
        // (UniFFI snake-case heuristic — see 16-FFI-AUDIT.md "Swift type name
        // reference card").
        let metaType = Ds3SessionHandle.self
        XCTAssertNotNil(String(describing: metaType))
    }

    /// Exercises the `conflict_key` UniFFI free function exposed by ds3-sync
    /// via ds3-ffi. Pure-function: no I/O, no Rust panic surface. Verifies
    /// the FFI dispatch path end-to-end (Swift -> C ABI -> Rust -> back).
    func testConflictKeyFreeFunction() {
        let result = conflictKey(
            originalKey: "foo/bar.txt",
            hostname: "test",
            nonce: nil
        )
        XCTAssertFalse(result.isEmpty, "conflictKey returned empty string")
        XCTAssertTrue(
            result.contains("Conflict on test"),
            "conflictKey output '\(result)' missing expected 'Conflict on test' substring"
        )
    }
}
