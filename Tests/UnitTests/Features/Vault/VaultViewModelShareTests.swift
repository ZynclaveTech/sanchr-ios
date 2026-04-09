import XCTest
@testable import Sanchr
import SanchrShared

@MainActor
final class VaultViewModelShareTests: XCTestCase {

    // MARK: - requestSave — photos/videos route through PhotosSaver

    func test_requestSave_photo_callsPhotosSaver() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("png-bytes".utf8))
        let photosSaver = SpyPhotosSaver()
        let viewModel = VaultViewModel()

        let photo = Self.makeVaultItem(
            id: "p1",
            name: "photo.jpg",
            type: .photo,
            sizeBytes: 9
        )

        await viewModel.requestSave(
            photo,
            vaultRepository: vaultRepo,
            photosSaver: photosSaver
        )

        XCTAssertEqual(photosSaver.saveCalls.count, 1)
        XCTAssertEqual(photosSaver.saveCalls.first?.mediaType, .photo)
        XCTAssertEqual(photosSaver.saveCalls.first?.filename, "photo.jpg")
        XCTAssertNil(viewModel.shareState, "state must be cleared after save")
        XCTAssertEqual(viewModel.shareCompletionToast, "Saved to Photos")
    }

    func test_requestSave_video_callsPhotosSaver() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("mp4-bytes".utf8))
        let photosSaver = SpyPhotosSaver()
        let viewModel = VaultViewModel()

        let video = Self.makeVaultItem(
            id: "v1",
            name: "clip.mp4",
            type: .video,
            sizeBytes: 9
        )

        await viewModel.requestSave(
            video,
            vaultRepository: vaultRepo,
            photosSaver: photosSaver
        )

        XCTAssertEqual(photosSaver.saveCalls.count, 1)
        XCTAssertEqual(photosSaver.saveCalls.first?.mediaType, .video)
        XCTAssertEqual(viewModel.shareCompletionToast, "Saved to Photos")
    }

    // MARK: - requestSave — documents/audio/notes produce a file-export state

    func test_requestSave_document_producesExportingToFilesState() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("pdf-bytes".utf8))
        let photosSaver = SpyPhotosSaver()
        let viewModel = VaultViewModel()

        let doc = Self.makeVaultItem(
            id: "d1",
            name: "report.pdf",
            type: .document,
            sizeBytes: 9
        )

        await viewModel.requestSave(
            doc,
            vaultRepository: vaultRepo,
            photosSaver: photosSaver
        )

        // PhotosSaver must NOT be called for documents.
        XCTAssertEqual(photosSaver.saveCalls.count, 0)

        // State is .exportingToFiles with a readable temp URL preserving
        // the original filename.
        guard case .exportingToFiles(let stateItem, let tempURL) = viewModel.shareState else {
            XCTFail("expected .exportingToFiles, got \(String(describing: viewModel.shareState))")
            return
        }
        XCTAssertEqual(stateItem.id, "d1")
        XCTAssertEqual(tempURL.lastPathComponent, "report.pdf")

        let onDisk = try Data(contentsOf: tempURL)
        XCTAssertEqual(onDisk, Data("pdf-bytes".utf8))

        // Cleanup
        viewModel.didFinishFilesExport(for: stateItem, tempURL: tempURL, success: true)
    }

    // MARK: - requestSave — download failure surfaces errorMessage, clears state

    func test_requestSave_downloadFailure_setsErrorMessage_clearsState() async {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .failure(
            AppError.decryptionFailed(reason: "no key")
        )
        let photosSaver = SpyPhotosSaver()
        let viewModel = VaultViewModel()

        let item = Self.makeVaultItem(id: "x", name: "x.jpg", type: .photo, sizeBytes: 1)

        await viewModel.requestSave(
            item,
            vaultRepository: vaultRepo,
            photosSaver: photosSaver
        )

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.shareState)
        XCTAssertEqual(photosSaver.saveCalls.count, 0)
        XCTAssertNil(viewModel.shareCompletionToast)
    }

    // MARK: - requestSave — concurrent calls are no-ops while one is in flight

    func test_requestSave_whileAnotherSaveInFlight_isNoop() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("x".utf8))
        let photosSaver = SpyPhotosSaver()
        let viewModel = VaultViewModel()

        let item = Self.makeVaultItem(id: "i", name: "i.jpg", type: .photo, sizeBytes: 1)

        // Simulate a save already in flight by pre-setting the guard
        // state, then call requestSave. The guard kicks in and the
        // call is a no-op.
        viewModel.shareState = .saving(item)

        await viewModel.requestSave(
            item,
            vaultRepository: vaultRepo,
            photosSaver: photosSaver
        )

        // No Photos save should have been triggered.
        XCTAssertEqual(photosSaver.saveCalls.count, 0)
        // State is still .saving because we manually set it and the
        // guard returned without entering the defer.
        guard case .saving = viewModel.shareState else {
            XCTFail("state should still be .saving")
            return
        }
    }

    // MARK: - didFinishFilesExport cleans up temp file + sets toast

    func test_didFinishFilesExport_success_deletesTempDir_setsToast() throws {
        let viewModel = VaultViewModel()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let tempURL = tempDir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let item = Self.makeVaultItem(id: "d", name: "doc.pdf", type: .document, sizeBytes: 1)
        viewModel.didFinishFilesExport(for: item, tempURL: tempURL, success: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        XCTAssertEqual(viewModel.shareCompletionToast, "Saved")
        XCTAssertNil(viewModel.shareState)
    }

    func test_didFinishFilesExport_cancel_deletesTempDir_noToast() throws {
        let viewModel = VaultViewModel()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let tempURL = tempDir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: tempURL)

        let item = Self.makeVaultItem(id: "d", name: "doc.pdf", type: .document, sizeBytes: 1)
        viewModel.didFinishFilesExport(for: item, tempURL: tempURL, success: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        XCTAssertNil(viewModel.shareCompletionToast)
        XCTAssertNil(viewModel.shareState)
    }

    // MARK: - takeShareCompletionToast consumes exactly once

    func test_takeShareCompletionToast_returnsAndClears() {
        let viewModel = VaultViewModel()
        viewModel.shareCompletionToast = "Saved"

        XCTAssertEqual(viewModel.takeShareCompletionToast(), "Saved")
        XCTAssertNil(viewModel.shareCompletionToast)
        XCTAssertNil(viewModel.takeShareCompletionToast())
    }

    // MARK: - Helpers

    private static func makeVaultItem(
        id: String,
        name: String,
        type: VaultItem.VaultItemType,
        sizeBytes: Int64
    ) -> VaultItem {
        VaultItem(
            id: id,
            mediaId: "media-\(id)",
            name: name,
            type: type,
            sizeBytes: sizeBytes,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - Test doubles

/// Spy for `PhotosSaving`. Marked `@unchecked Sendable` to satisfy the
/// protocol's `Sendable` requirement; the tests run on `@MainActor` so
/// calls are serialized and no explicit synchronization is needed.
final class SpyPhotosSaver: PhotosSaving, @unchecked Sendable {
    struct Call {
        let data: Data
        let mediaType: VaultItem.VaultItemType
        let filename: String
    }

    var saveCalls: [Call] = []
    var error: Error?

    func save(
        data: Data,
        mediaType: VaultItem.VaultItemType,
        suggestedFilename: String
    ) async throws {
        if let error { throw error }
        saveCalls.append(Call(data: data, mediaType: mediaType, filename: suggestedFilename))
    }
}
