//
//  PDFExporter.swift
//  OpenCaptions
//
//  Exports a session summary as a PDF and saves it via NSSavePanel.
//  Ported from the iOS `PDFExporter`, swapping the UIKit render path
//  (UIPrintPageRenderer) for macOS `WKWebView.createPDF`. Headings are
//  hardcoded English (this target has no LanguageManager) and there is no
//  analytics logging (no Firebase on macOS).
//

import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
enum PDFExporter {

    // MARK: - A4 page dimensions (72 dpi points)

    private static let a4Width: CGFloat = 595.0
    private static let a4Height: CGFloat = 842.0

    // MARK: - Public API

    /// Builds a summary PDF and presents an `NSSavePanel` to save it.
    /// No-ops (with a system beep) if rendering fails or the user cancels.
    static func exportSummary(
        title: String,
        date: Date,
        paragraphs: [String],
        keyPoints: [String],
        actionItems: [String]
    ) async {
        let html = buildHTML(
            title: title, date: date,
            paragraphs: paragraphs, keyPoints: keyPoints, actionItems: actionItems
        )

        guard let data = await renderHTMLToPDF(html: html) else {
            NSSound.beep()
            print("❌ Failed to render PDF")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sanitizedFilename(title: title, date: date)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            print("✅ PDF exported to:", url.path)
        } catch {
            NSSound.beep()
            print("❌ Failed to write PDF:", error)
        }
    }

    // MARK: - HTML → PDF via WKWebView

    private static func renderHTMLToPDF(html: String) async -> Data? {
        let rect = NSRect(x: 0, y: 0, width: a4Width, height: a4Height)
        let webView = WKWebView(frame: rect)
        // Off-screen host window so WebKit performs a full layout pass before we
        // snapshot; a detached web view can otherwise render blank.
        let hostWindow = NSWindow(
            contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false
        )
        hostWindow.contentView = webView

        let delegate = PDFNavigationDelegate()
        webView.navigationDelegate = delegate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { continuation.resume() }
            webView.loadHTMLString(html, baseURL: nil)
        }

        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(returning: try? result.get())
            }
        }

        hostWindow.contentView = nil   // keeps hostWindow alive across the awaits, then tears down
        return data
    }

    // MARK: - HTML builder

    private static func buildHTML(
        title: String,
        date: Date,
        paragraphs: [String],
        keyPoints: [String],
        actionItems: [String]
    ) -> String {
        let formattedDate = date.formatted(date: .abbreviated, time: .shortened)
        var sections = ""

        if !paragraphs.isEmpty {
            let body = paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
            sections += sectionHTML(heading: "Overview", content: body)
        }
        if !keyPoints.isEmpty {
            let items = keyPoints.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
            sections += sectionHTML(heading: "Key Points", content: "<ul>\(items)</ul>")
        }
        if !actionItems.isEmpty {
            let items = actionItems.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
            sections += sectionHTML(heading: "Action Items", content: "<ul>\(items)</ul>")
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif;
                font-size: 13px;
                line-height: 1.5;
                color: #1a1a1a;
                padding: 40px;
                text-align: justify;
                text-align-last: left;
            }
            .header { margin-bottom: 24px; border-bottom: 1px solid #e0e0e0; padding-bottom: 16px; }
            .header h1 { font-size: 20px; font-weight: 700; margin-bottom: 4px; }
            .header .date { font-size: 12px; color: #888; }
            .section { margin-bottom: 20px; }
            .section h2 { font-size: 15px; font-weight: 700; margin-bottom: 8px; page-break-after: avoid; }
            .section p { margin-bottom: 8px; page-break-inside: avoid; }
            ul { padding-left: 20px; }
            ul li { margin-bottom: 6px; page-break-inside: avoid; }
        </style>
        </head>
        <body>
            <div class="header">
                <h1>\(escapeHTML(title))</h1>
                <div class="date">\(escapeHTML(formattedDate))</div>
            </div>
            \(sections)
        </body>
        </html>
        """
    }

    private static func sectionHTML(heading: String, content: String) -> String {
        """
        <div class="section">
            <h2>\(escapeHTML(heading))</h2>
            \(content)
        </div>
        """
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Filename helper

    private static func sanitizedFilename(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: date)

        let sanitized = title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .prefix(60)

        let name = sanitized.isEmpty ? "Summary" : String(sanitized)
        return "\(name)_\(timestamp).pdf"
    }
}

// MARK: - WKWebView Navigation Helper

private final class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish?()
    }
}
