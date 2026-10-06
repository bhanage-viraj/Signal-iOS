//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient

#if TESTABLE_BUILD

class MockUsernameApiClient: UsernameApiClient {

    // MARK: Confirm

    var confirmUsernameMocks = [(
        username: LibSignalClient.Username,
        usernameCiphertext: Data,
    ) async throws -> UUID]()

    func confirmUsername(
        _ username: LibSignalClient.Username,
        usernameCiphertext: Data,
    ) async throws -> UUID {
        return try await confirmUsernameMocks.removeFirst()(username, usernameCiphertext)
    }

    // MARK: Delete

    var deleteCurrentUsernameMocks = [() async throws -> Void]()
    func deleteCurrentUsername() async throws {
        try await deleteCurrentUsernameMocks.removeFirst()()
    }

    // MARK: Set link

    var setUsernameLinkMocks = [(
        usernameCiphertext: Data,
        keepLinkHandle: Bool,
    ) async throws -> UUID]()

    func setUsernameLink(usernameCiphertext: Data, keepLinkHandle: Bool) async throws -> UUID {
        return try await setUsernameLinkMocks.removeFirst()(usernameCiphertext, keepLinkHandle)
    }

    // MARK: Unimplemented

    func reserveUsernameHashes(_ usernameHashes: [UsernameHash]) async throws -> UsernameHash { owsFail("Not implemented!") }
    func lookupAci(forHashedUsername hashedUsername: Usernames.HashedUsername) async throws -> Aci? { owsFail("Not implemented!") }
    func getUsernameLink(handle: UUID, entropy: Data) async throws -> LibSignalClient.Username? { owsFail("Not implemented!") }
}

#endif
