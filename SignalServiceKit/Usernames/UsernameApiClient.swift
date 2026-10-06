//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension Usernames {
    public enum ApiClientReservationResult {
        case successful(Usernames.HashedUsername)
        case rejected
        case rateLimited
    }
}
