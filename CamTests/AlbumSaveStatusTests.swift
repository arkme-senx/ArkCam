import XCTest
import AVFoundation
@testable import Cam

final class AlbumSaveStatusTests: XCTestCase {
    func testAutomaticStateDoesNotMistakeManualRearSaveForCompletedComposite() {
        let download = AlbumDownloadReceipt(id: UUID(), mode: .rear, attemptedAt: Date(), phase: .saved, assetIdentifier: "rear")
        XCTAssertEqual(AlbumItemSaveState.resolve(automatic: true, receipt: nil, damaged: false,
            active: nil, waiting: "cooling", downloads: [download]), .waiting("cooling"))
        XCTAssertEqual(AlbumItemSaveState.resolve(automatic: false, receipt: nil, damaged: false,
            active: nil, waiting: "", downloads: [download]), .saved)
        XCTAssertEqual(AlbumItemSaveState.resolve(automatic: false, receipt: nil, damaged: false,
            active: nil, waiting: "", downloads: []), .unknown)
    }

    func testOnlyConfirmedCommitIsSavedAndInterruptedCommitNeedsReconciliation() throws {
        let receipt = try JSONDecoder().decode(AlbumSaveReceipt.self, from: Data(#"{"phase":"saved","assetIdentifier":"legacy"}"#.utf8))
        XCTAssertNil(receipt.timing)
        for (receipt, state) in [(receipt, AlbumItemSaveState.saved), (.init(phase: .writing), .uncertain), (.init(phase: .failed), .failed)] {
            XCTAssertEqual(AlbumItemSaveState.resolve(automatic: true, receipt: receipt, damaged: false,
                active: nil, waiting: "", downloads: []), state)
        }
        XCTAssertEqual(AlbumItemSaveState.resolve(automatic: true, receipt: .init(phase: .writing), damaged: false,
            active: .writing, waiting: "", downloads: []), .writing)
        XCTAssertEqual(AlbumItemSaveState.resolve(automatic: true, receipt: receipt, damaged: true,
            active: nil, waiting: "", downloads: []), .uncertain)
    }

    @MainActor
    func testManualReceiptsSurviveReloadAndDoNotAlterAutomaticReceiptOrOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), albumSaveMode: .dual)
        let original = Data("untouched-original".utf8)
        try original.write(to: draft.rearURL)
        let store = AlbumSaveStore(disk: disk)
        try store.write(.init(phase: .saved, assetIdentifier: "combined"), for: draft.item.id)
        var entry = AlbumDownloadReceipt(id: UUID(), mode: .front, attemptedAt: Date(), phase: .writing)
        try store.writeDownload(entry, for: draft.item.id)
        entry.phase = .saved; entry.assetIdentifier = "front"
        try store.writeDownload(entry, for: draft.item.id)
        let reread = AlbumSaveStore(disk: LibraryDisk(root: root))
        XCTAssertEqual(try reread.downloads(draft.item.id), [entry])
        XCTAssertEqual(try reread.receipt(draft.item.id)?.assetIdentifier, "combined")
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), original)
        try Data("broken".utf8).write(to: draft.folder.appendingPathComponent("album-downloads.json"))
        XCTAssertThrowsError(try store.writeDownload(entry, for: draft.item.id))
        XCTAssertEqual(try Data(contentsOf: draft.folder.appendingPathComponent("album-downloads.json")), Data("broken".utf8))
    }

    @MainActor
    func testPhotoLaneIsBoundedAndThermallyGated() {
        let highResolution = MemoryItem(id: UUID(), createdAt: Date(), kind: .photo,
            capturedLayout: CameraLayout(), photoProfile: PhotoCaptureProfile(megapixels: 48))
        XCTAssertTrue(AutoAlbumSaver.isHeavy(highResolution))
        XCTAssertTrue(AutoAlbumSaver.canSchedule(heavy: false, activeHeavy: [true], allowPhotoLane: true))
        XCTAssertTrue(AutoAlbumSaver.canSchedule(heavy: true, activeHeavy: [false], allowPhotoLane: true))
        XCTAssertFalse(AutoAlbumSaver.canSchedule(heavy: true, activeHeavy: [true], allowPhotoLane: true))
        XCTAssertFalse(AutoAlbumSaver.canSchedule(heavy: false, activeHeavy: [false], allowPhotoLane: true))
        XCTAssertFalse(AutoAlbumSaver.canSchedule(heavy: false, activeHeavy: [true, false], allowPhotoLane: true))
        XCTAssertFalse(AutoAlbumSaver.canSchedule(heavy: false, activeHeavy: [true], allowPhotoLane: false))
    }

    func testPassthroughRejectsCropResizeAndCadenceChanges() {
        let full = CGSize(width: 1080, height: 1920)
        XCTAssertTrue(MediaExporter.canPassthrough(sourceSize: full, targetSize: full, sourceFPS: 30, targetFPS: 30))
        XCTAssertFalse(MediaExporter.canPassthrough(sourceSize: full, targetSize: CGSize(width: 1080, height: 1440), sourceFPS: 30, targetFPS: 30))
        XCTAssertFalse(MediaExporter.canPassthrough(sourceSize: full, targetSize: CGSize(width: 720, height: 1280), sourceFPS: 30, targetFPS: 30))
        XCTAssertFalse(MediaExporter.canPassthrough(sourceSize: full, targetSize: full, sourceFPS: 15, targetFPS: 30))
        XCTAssertFalse(MediaExporter.canPassthrough(sourceSize: full, targetSize: full, sourceFPS: .nan, targetFPS: 30))
    }
}
