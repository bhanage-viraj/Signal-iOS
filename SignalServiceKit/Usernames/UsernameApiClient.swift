//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import LibSignalClient

/// Manages usernames-related API calls.
public protocol UsernameApiClient {

    // MARK: Selection

    /// Reserves one of the given username hashes.
    ///
    /// - Returns: The username hash that was reserved.
    func reserveUsernameHashes(
        _ usernameHashes: [UsernameHash],
    ) async throws -> UsernameHash

    /// Confirms the given username, which must have previously been reserved.
    ///
    /// - Parameter usernameCiphertext: An encrypted form of this username for use in a username link.
    func confirmUsername(
        _ username: Username,
        usernameCiphertext: Data,
    ) async throws -> UUID

    // MARK: Deletion

    /// Delete the username and username link for the current user.
    func deleteCurrentUsername() async throws

    // MARK: Lookup

    /// Looks up the ACI corresponding to the given username, if one exists.
    func lookupAci(
        forHashedUsername hashedUsername: Usernames.HashedUsername,
    ) async throws -> Aci?

    // MARK: Links

    /// Set the encrypted username for the local user's username link.
    ///
    /// - SeeAlso
    /// ``Usernames.UsernameLink`` and ``UsernameLinkManager``.
    ///
    /// - Parameter usernameCiphertext
    /// The new encrypted username for the username link.
    /// - Parameter keepLinkHandle
    /// Whether we should ask the service to keep the existing link handle the
    /// same, rather than rotating it. Intended for use specifically in
    /// ``LocalUsernameManager/updateVisibleCaseOfExistingUsername``.
    /// - Returns
    /// The handle for the local user's encrypted username.
    func setUsernameLink(
        usernameCiphertext: Data,
        keepLinkHandle: Bool,
    ) async throws -> UUID

    /// Gets and decrypts the username for the given handle and entropy, if any.
    ///
    /// - SeeAlso
    /// ``Usernames.UsernameLink`` and ``UsernameLinkManager``.
    func getUsernameLink(handle: UUID, entropy: Data) async throws -> LibSignalClient.Username?
}

public extension Usernames {
    enum ApiClientReservationResult {
        case successful(Usernames.HashedUsername)
        case rejected
        case rateLimited
    }

    enum ApiClientConfirmationResult {
        /// The reservation was successfully confirmed.
        case success(usernameLinkHandle: UUID)
        /// The reservation was rejected. This may be because we no longer hold
        /// the reservation, the reservation lapsed, or something about the
        /// reservation was invalid.
        case rejected
        /// The reservation failed because we have been rate-limited.
        case rateLimited
    }
}
