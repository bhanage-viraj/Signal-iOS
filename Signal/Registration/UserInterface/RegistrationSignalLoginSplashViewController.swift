//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI
import SwiftUI

// MARK: -

@MainActor
protocol RegistrationSignalLoginSplashPresenter: AnyObject {
    func exitSignalLogin()
    func purchaseSignalLogin()
}

// MARK: -

public struct RegistrationSignalLoginSplashState: Equatable {
    var formattedPrice: String
}

// MARK: -

final class RegistrationSignalLoginSplashViewController: OWSViewController {
    private let state: RegistrationSignalLoginSplashState
    private weak var presenter: (any RegistrationSignalLoginSplashPresenter)?

    init(state: RegistrationSignalLoginSplashState, presenter: any RegistrationSignalLoginSplashPresenter) {
        self.state = state
        self.presenter = presenter
        super.init()
    }

    private lazy var titleImageView: UIImageView = {
        let result = UIImageView(image: .signalLogin)
        result.contentMode = .center
        return result
    }()

    private lazy var titleLabel: UILabel = {
        return UILabel.titleLabelForRegistration(text: titleText())
    }()

    private func titleText() -> String {
        return OWSLocalizedString(
            "REGISTRATION_SIGNAL_LOGIN_TITLE",
            comment: "Title text for the 'Signal Login' screen.",
        )
    }

    private lazy var explanationLabel: UILabel = {
        return UILabel.explanationLabelForRegistration(text: explanationText())
    }()

    private func explanationText() -> String {
        return OWSLocalizedString(
            "REGISTRATION_SIGNAL_LOGIN_EXPLANATION",
            comment: "Explanation text for the 'Signal Login' screen.",
        )
    }

    private lazy var continueButton = UIButton(
        configuration: .largePrimary(title: payText()),
        primaryAction: UIAction { [weak self] _ in
            self?.presenter?.purchaseSignalLogin()
        },
    )

    private func payText() -> String {
        let payFormat = OWSLocalizedString(
            "REGISTRATION_SIGNAL_LOGIN_PAY",
            comment: "Button to initiate a purchase on the 'Signal Login' screen. The replacement is a localized cost (e.g., $2.99).",
        )
        return String.nonPluralLocalizedStringWithFormat(payFormat, self.state.formattedPrice)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        addStaticContentStackView(arrangedSubviews: [
            titleImageView,
            titleLabel,
            explanationLabel,
            .vStretchingSpacer(),
            continueButton.enclosedInVerticalStackView(isFullWidthButton: true),
        ])

        navigationItem.leftBarButtonItem = .cancelButton { [weak self] in
            self?.presenter?.exitSignalLogin()
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
