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
            .appendingPathComponent("vault-save-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("vault-save-\(UUID().uuidString)", isDirectory: true)
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

    /// The cleanup must only ever delete a directory this flow made.
    ///
    /// With the export name unsanitised, a sender-chosen `../` put the temp
    /// URL under some other directory, and this cleanup then removed that
    /// directory's parent. The traversal is closed upstream; this is the
    /// second wall.
    func test_didFinishFilesExport_leavesAForeignDirectoryAlone() throws {
        let viewModel = VaultViewModel()
        let foreignDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-ours-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: foreignDir) }
        let tempURL = foreignDir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: tempURL)

        let item = Self.makeVaultItem(id: "d", name: "doc.pdf", type: .document, sizeBytes: 1)
        viewModel.didFinishFilesExport(for: item, tempURL: tempURL, success: true)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignDir.path),
            "a directory the flow did not create must survive its cleanup"
        )
    }

    // MARK: - takeShareCompletionToast consumes exactly once

    func test_takeShareCompletionToast_returnsAndClears() {
        let viewModel = VaultViewModel()
        viewModel.shareCompletionToast = "Saved"

        XCTAssertEqual(viewModel.takeShareCompletionToast(), "Saved")
        XCTAssertNil(viewModel.shareCompletionToast)
        XCTAssertNil(viewModel.takeShareCompletionToast())
    }

    // MARK: - requestShare (Flow B entry)

    func test_requestShare_setsChoosingDestinationState() {
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "s", name: "s.jpg", type: .photo, sizeBytes: 1)

        viewModel.requestShare(item)

        guard case .choosingDestination(let stateItem) = viewModel.shareState else {
            XCTFail("expected .choosingDestination, got \(String(describing: viewModel.shareState))")
            return
        }
        XCTAssertEqual(stateItem.id, "s")
    }

    func test_requestShare_whileSavingInFlight_isNoop() {
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "s", name: "s.jpg", type: .photo, sizeBytes: 1)
        viewModel.shareState = .saving(item)

        viewModel.requestShare(item)

        // Guard kicks in; state stays .saving.
        guard case .saving = viewModel.shareState else {
            XCTFail("state should still be .saving")
            return
        }
    }

    // MARK: - chooseShareInChat

    func test_chooseShareInChat_transitionsToPickingConversation() {
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "s", name: "s.jpg", type: .photo, sizeBytes: 1)

        viewModel.requestShare(item)
        viewModel.chooseShareInChat(for: item)

        guard case .pickingConversation(let stateItem) = viewModel.shareState else {
            XCTFail("expected .pickingConversation, got \(String(describing: viewModel.shareState))")
            return
        }
        XCTAssertEqual(stateItem.id, "s")
    }

    // MARK: - chooseShareOutside (Flow B2)

    func test_chooseShareOutside_happyPath_transitionsToExternalSharing() async {
        let coordinator = StubVaultSharingCoordinator()
        let expectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-share/UUID/doc.pdf")
        coordinator.prepareExternalResult = .success(expectedURL)

        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "o", name: "doc.pdf", type: .document, sizeBytes: 1)
        viewModel.shareState = .choosingDestination(item)

        await viewModel.chooseShareOutside(
            for: item,
            sharingCoordinator: coordinator
        )

        XCTAssertEqual(coordinator.prepareExternalCalls, ["o"])
        guard case .externalSharing(let stateItem, let tempURL) = viewModel.shareState else {
            XCTFail("expected .externalSharing, got \(String(describing: viewModel.shareState))")
            return
        }
        XCTAssertEqual(stateItem.id, "o")
        XCTAssertEqual(tempURL, expectedURL)
    }

    func test_chooseShareOutside_downloadFailure_setsErrorMessage_clearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        coordinator.prepareExternalResult = .failure(
            AppError.decryptionFailed(reason: "no key")
        )
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "o", name: "doc.pdf", type: .document, sizeBytes: 1)
        viewModel.shareState = .choosingDestination(item)

        await viewModel.chooseShareOutside(
            for: item,
            sharingCoordinator: coordinator
        )

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.shareState)
    }

    // MARK: - didFinishExternalShare

    func test_didFinishExternalShare_completed_setsToastAndClearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "f", name: "f.pdf", type: .document, sizeBytes: 1)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-share/UUID/f.pdf")
        viewModel.shareState = .externalSharing(item, tempURL: tempURL)

        viewModel.didFinishExternalShare(
            for: item,
            tempURL: tempURL,
            completed: true,
            sharingCoordinator: coordinator
        )

        // The cleanup Task is detached; give it a chance to run before
        // asserting.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.cleanupCalls, [tempURL])
        XCTAssertEqual(viewModel.shareCompletionToast, "Shared")
        XCTAssertNil(viewModel.shareState)
    }

    func test_didFinishExternalShare_cancelled_noToast_clearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "f", name: "f.pdf", type: .document, sizeBytes: 1)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-share/UUID/f.pdf")
        viewModel.shareState = .externalSharing(item, tempURL: tempURL)

        viewModel.didFinishExternalShare(
            for: item,
            tempURL: tempURL,
            completed: false,
            sharingCoordinator: coordinator
        )

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.cleanupCalls, [tempURL])
        XCTAssertNil(viewModel.shareCompletionToast)
        XCTAssertNil(viewModel.shareState)
    }

    // MARK: - confirmConversation (Flow B1 size check)

    func test_confirmConversation_under25MB_goesDirectlyAndClearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        coordinator.shareToChatResult = .success(
            VaultSharingCoordinator.ShareOutcome(conversationId: "conv-a", bytesUploaded: 5_000_000)
        )

        let viewModel = VaultViewModel()
        let smallItem = Self.makeVaultItem(
            id: "sm",
            name: "sm.jpg",
            type: .photo,
            sizeBytes: 5 * 1024 * 1024  // 5 MB
        )
        viewModel.shareState = .pickingConversation(smallItem)

        await viewModel.confirmConversation(
            conversationId: "conv-a",
            conversationName: "Alice",
            for: smallItem,
            sharingCoordinator: coordinator
        )

        XCTAssertEqual(coordinator.shareToChatCalls.count, 1)
        XCTAssertNil(viewModel.shareState)
        XCTAssertEqual(viewModel.shareCompletionToast, "Sent to Alice")
    }

    func test_confirmConversation_over25MB_transitionsToConfirmingLargeReupload() async {
        let coordinator = StubVaultSharingCoordinator()
        let viewModel = VaultViewModel()
        let bigItem = Self.makeVaultItem(
            id: "big",
            name: "big.mp4",
            type: .video,
            sizeBytes: 30 * 1024 * 1024  // 30 MB
        )
        viewModel.shareState = .pickingConversation(bigItem)

        await viewModel.confirmConversation(
            conversationId: "conv-b",
            conversationName: "Bob",
            for: bigItem,
            sharingCoordinator: coordinator
        )

        // No direct send — user must confirm first.
        XCTAssertEqual(coordinator.shareToChatCalls.count, 0)

        guard case .confirmingLargeReupload(let item, let cid, let cname, let sz) = viewModel.shareState else {
            XCTFail("expected .confirmingLargeReupload, got \(String(describing: viewModel.shareState))")
            return
        }
        XCTAssertEqual(item.id, "big")
        XCTAssertEqual(cid, "conv-b")
        XCTAssertEqual(cname, "Bob")
        XCTAssertEqual(sz, 30 * 1024 * 1024)
    }

    // MARK: - confirmLargeReupload

    func test_confirmLargeReupload_proceedsAndClearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        coordinator.shareToChatResult = .success(
            VaultSharingCoordinator.ShareOutcome(conversationId: "conv-b", bytesUploaded: 30_000_000)
        )

        let viewModel = VaultViewModel()
        let bigItem = Self.makeVaultItem(
            id: "big",
            name: "big.mp4",
            type: .video,
            sizeBytes: 30 * 1024 * 1024
        )
        viewModel.shareState = .confirmingLargeReupload(
            bigItem,
            conversationId: "conv-b",
            conversationName: "Bob",
            sizeBytes: 30 * 1024 * 1024
        )

        await viewModel.confirmLargeReupload(sharingCoordinator: coordinator)

        XCTAssertEqual(coordinator.shareToChatCalls.count, 1)
        XCTAssertNil(viewModel.shareState)
        XCTAssertEqual(viewModel.shareCompletionToast, "Sent to Bob")
    }

    func test_confirmLargeReupload_wrongState_isNoop() async {
        let coordinator = StubVaultSharingCoordinator()
        let viewModel = VaultViewModel()
        viewModel.shareState = nil  // not in .confirmingLargeReupload

        await viewModel.confirmLargeReupload(sharingCoordinator: coordinator)

        XCTAssertEqual(coordinator.shareToChatCalls.count, 0)
    }

    // MARK: - cancelLargeReupload

    func test_cancelLargeReupload_returnsToPickingConversation() {
        let viewModel = VaultViewModel()
        let bigItem = Self.makeVaultItem(
            id: "big",
            name: "big.mp4",
            type: .video,
            sizeBytes: 30 * 1024 * 1024
        )
        viewModel.shareState = .confirmingLargeReupload(
            bigItem,
            conversationId: "conv-b",
            conversationName: "Bob",
            sizeBytes: 30 * 1024 * 1024
        )

        viewModel.cancelLargeReupload()

        guard case .pickingConversation(let item) = viewModel.shareState else {
            XCTFail("expected .pickingConversation after cancel")
            return
        }
        XCTAssertEqual(item.id, "big")
    }

    // MARK: - cancelShare

    func test_cancelShare_clearsState() {
        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(id: "c", name: "c.jpg", type: .photo, sizeBytes: 1)
        viewModel.shareState = .choosingDestination(item)

        viewModel.cancelShare()

        XCTAssertNil(viewModel.shareState)
    }

    // MARK: - performShareToChat (Flow B1) failure path

    func test_performShareToChat_sendFailure_setsErrorMessage_clearsState() async {
        let coordinator = StubVaultSharingCoordinator()
        coordinator.shareToChatResult = .failure(
            AppError.grpcError(code: 13, message: "boom")
        )

        let viewModel = VaultViewModel()
        let item = Self.makeVaultItem(
            id: "fail",
            name: "fail.jpg",
            type: .photo,
            sizeBytes: 1_000_000  // under threshold so goes direct
        )
        viewModel.shareState = .pickingConversation(item)

        await viewModel.confirmConversation(
            conversationId: "conv-f",
            conversationName: "Fran",
            for: item,
            sharingCoordinator: coordinator
        )

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.shareState)
        XCTAssertNil(viewModel.shareCompletionToast)
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

// MARK: - StubVaultSharingCoordinator

/// Test double for `VaultSharingCoordinating`. Lets Task 6 tests drive
/// the view model's Flow B state machine without touching real
/// coordinator state.
final class StubVaultSharingCoordinator: VaultSharingCoordinating, @unchecked Sendable {
    struct ShareToChatCall {
        let itemId: String
        let conversationId: String
    }

    var prepareExternalResult: Result<URL, Error> = .success(
        FileManager.default.temporaryDirectory.appendingPathComponent("stub-temp")
    )
    var shareToChatResult: Result<VaultSharingCoordinator.ShareOutcome, Error> = .success(
        VaultSharingCoordinator.ShareOutcome(conversationId: "", bytesUploaded: 0)
    )

    private(set) var prepareExternalCalls: [String] = []
    private(set) var cleanupCalls: [URL] = []
    private(set) var shareToChatCalls: [ShareToChatCall] = []

    func prepareForExternalShare(item: VaultItem) async throws -> URL {
        prepareExternalCalls.append(item.id)
        switch prepareExternalResult {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    func cleanupTempFile(at url: URL) async {
        cleanupCalls.append(url)
    }

    func shareToChat(
        item: VaultItem,
        conversationId: String
    ) async throws -> VaultSharingCoordinator.ShareOutcome {
        shareToChatCalls.append(
            ShareToChatCall(itemId: item.id, conversationId: conversationId)
        )
        switch shareToChatResult {
        case .success(let outcome): return outcome
        case .failure(let error): throw error
        }
    }

    func reshareToCurrentChat(
        item: VaultItem,
        conversationId: String
    ) async throws -> VaultSharingCoordinator.ShareOutcome {
        try await shareToChat(item: item, conversationId: conversationId)
    }
}
