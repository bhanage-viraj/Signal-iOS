//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalRingRTC
import XCTest

@testable import SignalServiceKit

class LocalUsernameManagerTests: XCTestCase {
    private var mockDB: InMemoryDB!
    private var mockReachabilityManager: MockReachabilityManager!
    private var mockStorageServiceManager: MockStorageServiceManager!
    private var mockSyncMessageSender: MockUsernameChangeSyncMessageSender!
    private var mockTSAccountManager: MockTSAccountManager!
    private var mockUsernamesService: MockUsernamesService!

    private var localUsernameManager: LocalUsernameManager!

    override func setUp() {
        mockDB = InMemoryDB()

        mockReachabilityManager = MockReachabilityManager()
        mockStorageServiceManager = MockStorageServiceManager()
        mockSyncMessageSender = MockUsernameChangeSyncMessageSender()
        mockTSAccountManager = MockTSAccountManager()
        mockUsernamesService = MockUsernamesService()

        setLocalUsernameManager(maxNetworkRequestRetries: 0)
    }

    private func setLocalUsernameManager(maxNetworkRequestRetries: Int) {
        localUsernameManager = LocalUsernameManagerImpl(
            db: mockDB,
            keyTransparencyStore: KeyTransparencyStore(),
            reachabilityManager: mockReachabilityManager,
            serviceProvider: MockServiceProvider(mockServices: [mockUsernamesService!]),
            storageServiceManager: mockStorageServiceManager,
            syncMessageSender: mockSyncMessageSender,
            tsAccountManager: mockTSAccountManager,
            maxNetworkRequestRetries: maxNetworkRequestRetries,
        )
    }

    override func tearDown() {
        owsPrecondition(mockUsernamesService.confirmUsernameMocks.get().isEmpty)
        owsPrecondition(mockUsernamesService.deleteUsernameHashMocks.get().isEmpty)
        owsPrecondition(mockUsernamesService.setUsernameLinkMocks.get().isEmpty)
    }

    // MARK: Local state changes

    func testLocalUsernameStateChanges() {
        let linkHandle = UUID()

        XCTAssertEqual(usernameState(), .unset)

        mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: "boba-fett",
                usernameLink: .mock(handle: linkHandle),
                tx: tx,
            )
        }

        XCTAssertEqual(
            usernameState(),
            .available(username: "boba-fett", usernameLink: .mock(handle: linkHandle)),
        )

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba-fett",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba-fett"))

        mockDB.write { tx in
            localUsernameManager.clearLocalUsername(tx: tx)
        }

        XCTAssertEqual(usernameState(), .unset)
    }

    func testUsernameQRCodeColorChanges() {
        func color() -> QRCodeColor {
            return mockDB.read { tx in
                return localUsernameManager.usernameLinkQRCodeColor(tx: tx)
            }
        }

        XCTAssertEqual(color(), .unknown)

        mockDB.write { tx in
            localUsernameManager.setUsernameLinkQRCodeColor(
                color: .olive,
                tx: tx,
            )
        }

        XCTAssertEqual(color(), .olive)
    }

    // MARK: Confirmation

    func testConfirmUsernameHappyPath() async {
        let linkHandle = UUID()
        let username = "boba_fett.42"

        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in linkHandle }])

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock(username))

        XCTAssertEqual(value, .success(.success))
        XCTAssertEqual(usernameState().username, username)
        XCTAssertEqual(usernameState().usernameLink?.handle, linkHandle)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testConfirmBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileConfirming() async {
        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in throw OWSHTTPError.mockNetworkFailure }])

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.42"))

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileConfirming() async {
        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in throw OWSGenericError("") }])

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.42"))

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfRejectedWhileConfirming() async {
        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in throw SignalError.usernameReservationNotFound("") }])

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .success(.rejected))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfRateLimitedWhileConfirming() async {
        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in throw SignalError.rateLimitedError(retryAfter: 60, message: "") }])

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .success(.rateLimited))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testSuccessfulConfirmationClearsLinkCorruption() async {
        let newHandle = UUID()

        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in newHandle }])

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.confirmUsername(reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"))

        XCTAssertEqual(value, .success(.success))
        XCTAssertEqual(usernameState().username, "boba_fett.43")
        XCTAssertEqual(usernameState().usernameLink?.handle, newHandle)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testSuccessfulConfirmationClearsUsernameCorruption() async {
        let newHandle = UUID()

        mockUsernamesService.confirmUsernameMocks.set([{ _, _ in newHandle }])

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let value = await localUsernameManager.confirmUsername(reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"))

        XCTAssertEqual(value, .success(.success))
        XCTAssertEqual(usernameState().username, "boba_fett.43")
        XCTAssertEqual(usernameState().usernameLink?.handle, newHandle)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    // MARK: Deletion

    func testDeletionHappyPath() async {
        mockUsernamesService.deleteUsernameHashMocks.set([{}])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testDeleteBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileDeleting() async {
        mockUsernamesService.deleteUsernameHashMocks.set([{ throw OWSHTTPError.mockNetworkFailure }])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileDeleting() async {
        mockUsernamesService.deleteUsernameHashMocks.set([{ throw OWSGenericError("") }])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isOtherError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testDeletionClearsCorruption() async {
        mockUsernamesService.deleteUsernameHashMocks.set([{}])

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testDeletionClearsLinkCorruption() async {
        mockUsernamesService.deleteUsernameHashMocks.set([{}])

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    // MARK: Rotate link

    func testRotationHappyPath() async {
        let newHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([{ _, _ in newHandle }])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual((try? value.get())?.handle, newHandle)
        XCTAssertEqual(usernameState().username, "boba_fett.42")
        XCTAssertEqual(usernameState().usernameLink?.handle, newHandle)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testRotationBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfFailToGenerateNewLink() async {
        let stateBeforeRotate = setUsername(username: "boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett_boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), stateBeforeRotate)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileRotatingLink() async {
        mockUsernamesService.setUsernameLinkMocks.set([{ _, _ in throw OWSHTTPError.mockNetworkFailure }])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileRotatingLink() async {
        mockUsernamesService.setUsernameLinkMocks.set([{ _, _ in throw OWSGenericError("") }])

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testSuccessfulRotationClearsCorruption() async {
        let newHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([{ _, _ in newHandle }])

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual((try? value.get())?.handle, newHandle)
        XCTAssertEqual(usernameState().username, "boba_fett.42")
        XCTAssertEqual(usernameState().usernameLink?.handle, newHandle)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseHappyPath() async {
        let linkHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            return linkHandle
        }])

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfNetworkError() async {
        let linkHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            throw OWSHTTPError.mockNetworkFailure
        }])

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42"),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfError() async {
        let linkHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            throw OWSGenericError("oopsie")
        }])

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isOtherError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42"),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    // MARK: Network retries

    func testUpdateVisibleCaseWorkSecondTimeAfterNetworkError() async {
        setLocalUsernameManager(maxNetworkRequestRetries: 1)

        let linkHandle = UUID()

        mockUsernamesService.setUsernameLinkMocks.set([
            { _, keepLinkHandle in
                XCTAssertTrue(keepLinkHandle)
                throw OWSHTTPError.mockNetworkFailure
            },
            { _, keepLinkHandle in
                XCTAssertTrue(keepLinkHandle)
                return linkHandle
            },
        ])

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    // MARK: Utilities

    private func setUsername(
        username: String,
        linkHandle: UUID? = nil,
    ) -> Usernames.LocalUsernameState {
        return mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: username,
                usernameLink: .mock(handle: linkHandle ?? UUID()),
                tx: tx,
            )

            return localUsernameManager.usernameState(tx: tx)
        }
    }

    private func usernameState() -> Usernames.LocalUsernameState {
        return mockDB.read { tx in
            return localUsernameManager.usernameState(tx: tx)
        }
    }
}

private extension Usernames.RemoteMutationResult<Void> {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }

    var isNetworkError: Bool {
        switch self {
        case .failure(.networkError): return true
        case .success, .failure(.otherError): return false
        }
    }

    var isOtherError: Bool {
        switch self {
        case .failure(.otherError): return true
        case .success, .failure(.networkError): return false
        }
    }
}

// MARK: - Mocks

private extension OWSHTTPError {
    static var mockNetworkFailure: OWSHTTPError {
        return .networkFailure(.genericFailure)
    }
}

private extension Usernames.HashedUsername {
    static func mock(_ username: String) -> Usernames.HashedUsername {
        try! Usernames.HashedUsername(forUsername: username)
    }
}

private extension Usernames.UsernameLink {
    static func mock(handle: UUID) -> UsernameLink {
        return UsernameLink(
            handle: handle,
            entropy: .mockEntropy,
        )
    }
}

private extension UsernameLink.Entropy {
    static let mockEntropy = try! Self(rawValue: .mockEntropy)
}

private extension Data {
    static let mockEntropy = Data(repeating: 12, count: 32)
}

private class MockReachabilityManager: SSKReachabilityManager {
    var isReachable: Bool = true
    func isReachable(via reachabilityType: ReachabilityType) -> Bool { owsFail("Not implemented!") }
}

private class MockStorageServiceManager: StorageServiceManager {
    var didRecordPendingLocalAccountUpdates: Bool = false

    func recordPendingLocalAccountUpdates() {
        didRecordPendingLocalAccountUpdates = true
    }

    func setLocalIdentifiers(_ localIdentifiers: LocalIdentifiers) { owsFail("Not implemented!") }
    func registerForCron(_ cron: Cron) { owsFail("Not implemented.") }
    func currentManifestVersion(tx: DBReadTransaction) -> UInt64 { owsFail("Not implemented") }
    func currentManifestHasRecordIkm(tx: DBReadTransaction) -> Bool { owsFail("Not implemented") }
    func waitForPendingRestores() async throws { owsFail("Not implemented") }
    func waitForSteadyState() async throws(CancellationError) { owsFail("Not implemented") }
    func resetLocalData(transaction: DBWriteTransaction) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedRecipientUniqueIds: [RecipientUniqueId]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedAddresses: [SignalServiceAddress]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedGroupV2MasterKeys: [GroupMasterKey]) { owsFail("Not implemented!") }
    func recordPendingInsertions(forGroupMasterKeys groupMasterKeys: [GroupMasterKey]) {}
    func recordPendingUpdates(updatedStoryDistributionListIds: [Data]) { owsFail("Not implemented!") }
    func recordPendingUpdates(callLinkRootKeys: [CallLinkRootKey]) { owsFail("Not implemented!") }
    func backupPendingChanges(authedAccount: AuthedAccount) { owsFail("Not implemented!") }
    func restoreOrCreateManifestIfNecessary(authedAccount: AuthedAccount, masterKeySource: StorageService.MasterKeySource) async throws { owsFail("Not implemented!") }
    func rotateManifest(mode: ManifestRotationMode, authedAccount: AuthedAccount) async throws { owsFail("Not implemented!") }
}

private class MockUsernameChangeSyncMessageSender: LocalUsernameManagerImpl.UsernameChangeSyncMessageSender {
    var usernameChangeSyncMessageCount = 0

    func addUsernameChangeSyncMessage(tx: DBWriteTransaction) {
        usernameChangeSyncMessageCount += 1
    }
}
