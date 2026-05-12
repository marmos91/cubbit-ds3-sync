@testable import DS3Lib
import FileProvider
import XCTest

/// Phase A regression: the `.ds3keep` marker filename must never be
/// surfaced as a virtual folder by `S3Enumerator.synthesizeVirtualFolders`.
/// Filter behavior is covered by `S3KeyFilterTests` in DS3LibTests;
/// general synthesizer behavior is covered by `S3EnumeratorTests`.
/// This file pins the marker-specific negative invariant.
final class FolderMarkerEnumeratorTests: XCTestCase {
    func testSynthesizeVirtualFoldersDoesNotProduceMarkerAsFolder() {
        let drive = ProviderTestFixtures.makeDrive()
        let items = [
            ProviderTestFixtures.makeItem(key: "prefix/photos/.ds3keep", drive: drive)
        ]
        let virtual = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )
        let synthesizedKeys = Set(virtual.map(\.itemIdentifier.rawValue))
        XCTAssertFalse(
            synthesizedKeys.contains("prefix/photos/.ds3keep/"),
            "Marker filename must not be synthesized as a folder"
        )
    }
}
