@testable import DS3Lib
import FileProvider
import XCTest

/// Phase A: `S3Item.wireKey` rewrites folder PUTs to the `.ds3keep` marker
/// while leaving file PUTs and the in-memory identifier untouched.
final class S3ItemWireKeyTests: XCTestCase {
    func testWireKeyForFolderRewritesToMarker() {
        let drive = ProviderTestFixtures.makeDrive()
        let folder = ProviderTestFixtures.makeItem(key: "prefix/new-folder/", drive: drive)
        XCTAssertEqual(folder.wireKey, "prefix/new-folder/.ds3keep")
    }

    func testWireKeyForFileIsIdentifierKey() {
        let drive = ProviderTestFixtures.makeDrive()
        let file = ProviderTestFixtures.makeItem(key: "prefix/photo.jpg", drive: drive)
        XCTAssertEqual(file.wireKey, "prefix/photo.jpg")
    }

    func testWireKeyDoesNotMutateIdentifier() {
        // The identifier MUST remain "<folder>/" even after computing wireKey.
        // Identifier semantics (parentItemIdentifier, isFolder, etc.) depend on it.
        let drive = ProviderTestFixtures.makeDrive()
        let folder = ProviderTestFixtures.makeItem(key: "prefix/keep/", drive: drive)
        _ = folder.wireKey
        XCTAssertEqual(folder.itemIdentifier.rawValue, "prefix/keep/")
        XCTAssertTrue(folder.isFolder)
        // Parent resolution must still see the folder under the drive prefix
        // (real invariant — not just identifier text equality).
        XCTAssertEqual(folder.parentItemIdentifier, .rootContainer)
    }

    func testWireKeyForNestedFolder() {
        let drive = ProviderTestFixtures.makeDrive()
        let folder = ProviderTestFixtures.makeItem(key: "prefix/parent/child/", drive: drive)
        XCTAssertEqual(folder.wireKey, "prefix/parent/child/.ds3keep")
    }
}
