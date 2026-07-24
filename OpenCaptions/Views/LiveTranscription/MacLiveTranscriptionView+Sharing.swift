//
//  MacLiveTranscriptionView+Sharing.swift
//  OpenCaptions
//
//  Copy-Link share affordance for the live recording screen: mints (or reuses)
//  the shared Firestore session via the view model and copies its public link
//  to the clipboard, with a brief on-screen confirmation. Kept in a same-type
//  extension to hold MacLiveTranscriptionView under the 250-line file limit.
//  See docs/2026-07-06-macos-firestore-share.md.
//

import SwiftUI

extension MacLiveTranscriptionView {

    /// The primary-action Share toolbar item. Isolated here (rather than inline
    /// in `body`) both to keep the file short and so its conditional/ternary
    /// type-checks separately from the long `body` modifier chain. Reading the
    /// flag establishes an Observation dependency, so it appears/disappears when
    /// the remote flag flips.
    @ToolbarContentBuilder
    var shareToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if FeatureFlagService.shared.isEnabled(.sessionSharing) {
                Button(action: handleShare) {
                    Image(systemName: viewModel.isShared
                          ? "square.and.arrow.up.badge.checkmark"
                          : "square.and.arrow.up")
                }
                .help(viewModel.isShared ? "Copy share link" : "Share a public link")
                .accessibilityLabel("Share")
            }
        }
    }

    /// Mints (or reuses) the shared session and opens the share dialog (link +
    /// password controls). Share-to-web mirroring for the rest of the session
    /// continues automatically via the view model.
    func handleShare() {
        guard let id = viewModel.shareLive() else { return }
        shareTarget = ShareTarget(id: id)
    }
}
