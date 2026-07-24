//
//  MacSupportSettingsView.swift
//  OpenCaptions
//
//  The Settings → Support pane. Gives users an in-app way to reach us —
//  Send Feedback, Report a Problem, and Contact Support — each opening the default
//  mail client via a prefilled `mailto:`. "Report a Problem" seeds the body with
//  app/OS/account diagnostics for triage. A version footer rounds it out.
//  See docs/2026-07-15-macos-email-capture-and-support.md.
//

import AppKit
import SwiftUI

struct MacSupportSettingsView: View {
    @Environment(MacAuthManager.self) private var auth

    /// Single support inbox for all three actions (distinguished by subject line).
    /// Supplied per-deployment via the git-ignored Config.xcconfig (SUPPORT_EMAIL).
    private var supportEmail: String {
        Bundle.main.infoDictionary?["SUPPORT_EMAIL"] as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                supportRow(
                    title: "Send Feedback",
                    subtitle: "Share ideas and feature suggestions.",
                    systemImage: "lightbulb"
                ) { openMailto(subject: "Open Captions for Mac - Feedback") }

                supportRow(
                    title: "Report a Problem",
                    subtitle: "Something not working? Tell us what happened.",
                    systemImage: "exclamationmark.bubble"
                ) { openMailto(subject: "Open Captions for Mac - Bug Report", body: bugReportBody) }

                supportRow(
                    title: "Contact Support",
                    subtitle: "Get in touch with the Open Captions team.",
                    systemImage: "envelope"
                ) { openMailto(subject: "Open Captions for Mac - Support") }
            }

            Section {
                LabeledContent("Version", value: appVersionString)
                LabeledContent("macOS", value: osVersionString)
            } footer: {
                Text("Include the details above when reporting a problem — they help us reproduce it faster.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rows

    private func supportRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .appScaledFont(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appScaledFont(.body)
                    Text(subtitle)
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .appScaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Diagnostics

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Prefilled body for a bug report: a prompt for the user, then diagnostics.
    private var bugReportBody: String {
        """
        Describe the problem:


        ---
        The details below help us investigate — please keep them.
        App: Open Captions for Mac \(appVersionString)
        macOS: \(osVersionString)
        Account: \(auth.userEmail ?? "not signed in") · \(auth.userID ?? "—")
        """
    }

    // MARK: - Mail

    /// Opens the default mail client with a prefilled message. Percent-encoding is
    /// handled by `URLComponents` (spaces/newlines → `%20`/`%0A`).
    private func openMailto(subject: String, body: String? = nil) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        var items = [URLQueryItem(name: "subject", value: subject)]
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    MacSupportSettingsView()
        .environment(MacAuthManager.shared)
        .frame(width: 480, height: 460)
}
