//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

extension Usernames {
    public enum ApiClientReservationResult {
        case successful(LibSignalClient.Username)
        case rejected
        case rateLimited
    }
}
