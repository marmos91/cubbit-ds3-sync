@testable import DS3Lib
import FileProvider
import XCTest

/// Phase A regression: ensure `.ds3keep` marker objects are filtered out
/// of user-visible enumerations and never get synthesized into virtual
/// folders. The marker's job is to materialize the enclosing folder as
/// a CommonPrefix — not to appear as a child.
final class FolderMarkerEnumeratorTests: XCTestCase {
    // MARK: - S3KeyFilter behavior

    func testIsUserVisibleHidesMarker() {
        XCTAssertFalse(
            S3KeyFilter.isUserVisible(key: "prefix/photos/.ds3keep", drivePrefix: "prefix/")
        )
    }

    func testIsUserVisibleShowsLegacyFolderPlaceholder() {
        XCTAssertTrue(
            S3KeyFilter.isUserVisible(key: "prefix/photos/", drivePrefix: "prefix/")
        )
    }

    func testIsUserVisibleShowsRegularFile() {
        XCTAssertTrue(
            S3KeyFilter.isUserVisible(key: "prefix/photos/cat.jpg", drivePrefix: "prefix/")
        )
    }

    // MARK: - synthesizeVirtualFolders behavior

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
            "Marker must not be synthesized as a folder"
        )
    }

    func testSynthesizeVirtualFoldersSurfacesEnclosingFolderFromMarker() {
        // The marker exists *inside* the folder; the folder prefix itself
        // is what should surface when synthesizing virtual folders.
        let drive = ProviderTestFixtures.makeDrive()
        let items = [
            ProviderTestFixtures.makeItem(key: "prefix/photos/.ds3keep", drive: drive)
        ]
        let virtual = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )
        let synthesizedKeys = Set(virtual.map(\.itemIdentifier.rawValue))
        XCTAssertTrue(
            synthesizedKeys.contains("prefix/photos/"),
            "Folder containing the marker must surface as a virtual folder; got \(synthesizedKeys)"
        )
    }
}
