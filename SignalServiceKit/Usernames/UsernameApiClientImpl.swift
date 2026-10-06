//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import LibSignalClient

public class UsernameApiClientImpl: UsernameApiClient {
    private let chatConnectionManager: ChatConnectionManager

    init(chatConnectionManager: ChatConnectionManager) {
        self.chatConnectionManager = chatConnectionManager
    }

    // MARK: Selection

    public func reserveUsernameHashes(
        _ usernameHashes: [UsernameHash],
    ) async throws -> UsernameHash {
        return try await chatConnectionManager.withAuthService(.usernames) {
            return try await $0.reserveUsernameHashes(usernameHashes)
        }
    }

    public func confirmUsername(
        _ username: Username,
        usernameCiphertext: Data,
    ) async throws -> UUID {
        return try await chatConnectionManager.withAuthService(.usernames) {
            return try await $0.confirmUsername(username, usernameCiphertext: usernameCiphertext)
        }
    }

    // MARK: Deletion

    public func deleteCurrentUsername() async throws {
        try await chatConnectionManager.withAuthService(.usernames) {
            try await $0.deleteUsernameHash()
        }
    }

    // MARK: Lookup

    public func lookupAci(
        forHashedUsername hashedUsername: Usernames.HashedUsername,
    ) async throws -> Aci? {
        try await chatConnectionManager.withUnauthService(.usernames) {
            try await $0.lookUpUsernameHash(hashedUsername.rawHash)
        }
    }

    // MARK: Links

    public func setUsernameLink(
        usernameCiphertext: Data,
        keepLinkHandle: Bool,
    ) async throws -> UUID {
        return try await chatConnectionManager.withAuthService(.usernames) {
            return try await $0.setUsernameLink(usernameCiphertext: usernameCiphertext, keepLinkHandle: keepLinkHandle)
        }
    }

    public func getUsernameLink(
        handle: UUID,
        entropy: Data,
    ) async throws -> LibSignalClient.Username? {
        try await chatConnectionManager.withUnauthService(.usernames) {
            try await $0.lookUpUsernameLink(handle, entropy: entropy)
        }
    }
}
