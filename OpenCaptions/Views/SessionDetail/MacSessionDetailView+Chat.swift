//
//  MacSessionDetailView+Chat.swift
//  OpenCaptions
//
//  Chat tab: ask free-text questions about this session, grounded on its
//  transcript and answered by whichever provider is selected in Settings → AI
//  Models → Chat Model (`SessionChatService`). Split from MacSessionDetailView
//  to stay under the line limit, matching the +Playback/+Find/+Retranscription
//  convention. See docs/2026-09-16-macos-session-chat.md.
//

import AppKit
import SwiftData
import SwiftUI

extension MacSessionDetailView {

    var chatTab: some View {
        VStack(spacing: 0) {
            Group {
                if session.lines.isEmpty {
                    centered {
                        ContentUnavailableView(
                            "No Transcript Yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("This session has no transcript to ask questions about.")
                        )
                    }
                } else if let reason = chatProvider.unavailableReason, chatVM.messages.isEmpty {
                    // Only reachable when Apple Intelligence is selected but unavailable —
                    // OpenRouter has no static gate. An existing conversation stays
                    // readable (below); only asking something new is blocked.
                    centered {
                        ContentUnavailableView {
                            Label("Chat Unavailable", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Apple Intelligence isn't available right now (\(reason)). Select OpenRouter as the Chat Model in Settings to ask about this session.")
                        }
                    }
                } else if chatVM.messages.isEmpty {
                    centered {
                        ContentUnavailableView {
                            Label("Ask About This Session", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Ask a question grounded on this session's transcript — e.g. \"What did we decide about the deadline?\"")
                        }
                    }
                } else {
                    chatMessageList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = chatVM.errorMessage {
                chatErrorBanner(error)
            }
            chatInputBar
        }
    }

    // MARK: - Message list

    private var chatMessageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chatVM.messages) { message in
                        chatBubble(message).id(message.id)
                    }
                    if chatVM.isLoading {
                        chatTypingIndicator.id(chatLoadingAnchorID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            // Follows the conversation as it grows — both a newly appended message
            // and the typing indicator appearing/disappearing.
            .onChange(of: chatVM.messages.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: chatVM.isLoading) { _, _ in scrollToLatest(proxy) }
            // Clears the copy confirmation ~1.5 s later. Keyed on the id, so
            // copying a second message restarts the timer rather than letting the
            // first one's pending clear cut the new checkmark short.
            .task(id: copiedChatMessageID) {
                guard copiedChatMessageID != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation { copiedChatMessageID = nil }
            }
        }
    }

    /// Stable id for the typing indicator row, so `scrollToLatest` can target it
    /// while a response is in flight (there's no message to anchor to yet).
    private var chatLoadingAnchorID: String { "chat-loading-indicator" }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation {
            if chatVM.isLoading {
                proxy.scrollTo(chatLoadingAnchorID, anchor: .bottom)
            } else if let last = chatVM.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func chatBubble(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            // The copy button sits on the bubble's OUTER side — left of a
            // right-aligned user bubble, right of a left-aligned assistant one —
            // so it never covers text and always lands in the gutter.
            if message.role == .user {
                Spacer(minLength: 40)
                chatCopyButton(for: message)
            }
            messageText(message)
                .appScaledFont(.body)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(message.role == .user ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08))
                )
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role == .assistant {
                chatCopyButton(for: message)
                Spacer(minLength: 40)
            }
        }
        .onHover { isHovering in
            if isHovering {
                hoveredChatMessageID = message.id
            } else if hoveredChatMessageID == message.id {
                // Only clear when this row still owns the hover — the enter event
                // for the next row can arrive before this row's exit event.
                hoveredChatMessageID = nil
            }
        }
        // Right-click Copy as well as the hover button — matching the transcript
        // bubbles' own context menu, and reachable without hovering.
        .contextMenu {
            Button {
                copyChatMessage(message)
            } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
            }
        }
    }

    /// Hover-revealed copy button. Kept in the layout at zero opacity rather than
    /// conditionally inserted, so the bubble doesn't shift sideways as the pointer
    /// crosses the list. Stays visible while its own "copied" checkmark shows.
    private func chatCopyButton(for message: ChatMessage) -> some View {
        let isCopied = copiedChatMessageID == message.id
        return Button {
            copyChatMessage(message)
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                .appScaledFont(.caption)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isCopied ? "Copied" : "Copy message")
        .opacity(hoveredChatMessageID == message.id || isCopied ? 1 : 0)
        // Hidden from the accessibility tree while invisible, so VoiceOver doesn't
        // announce a control the user can't see or reach.
        .accessibilityHidden(hoveredChatMessageID != message.id && !isCopied)
    }

    /// Copies one message's text. For an assistant reply that's the RAW Markdown,
    /// not what `MarkdownMessageView` rendered, so pasting elsewhere keeps the
    /// headings, lists, and code fences. Hand-selecting the bubble still yields the
    /// rendered form, so both are available.
    private func copyChatMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        withAnimation { copiedChatMessageID = message.id }
    }

    /// Assistant replies are typically Markdown-formatted (lists, bold, headings,
    /// fenced code); user messages render as plain text since they're free-form
    /// input, not meant to be interpreted as Markdown. Block-level constructs route
    /// through `MarkdownMessageView`/`MarkdownBlockParser` — `LocalizedStringKey`
    /// alone only resolves inline styling (bold, italic, inline code, links), which
    /// still applies within each rendered block.
    @ViewBuilder
    private func messageText(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            MarkdownMessageView(markdown: message.text)
        } else {
            Text(message.text)
        }
    }

    private var chatTypingIndicator: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.08)))
            Spacer(minLength: 40)
        }
    }

    private func chatErrorBanner(_ message: String) -> some View {
        Text(message)
            .appScaledFont(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 4)
    }

    // MARK: - Input bar

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this session…", text: $chatVM.draftQuestion)
                .textFieldStyle(.plain)
                .onSubmit { sendChatMessage() }
            Button {
                sendChatMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .appScaledFont(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!chatVM.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassBackground(in: RoundedRectangle(cornerRadius: 18))
        // Capped + centered to match the player bar's width (`bottomBar` in
        // +Playback.swift), so the two bars align visually when switching between
        // the Transcript/Summary and Chat tabs.
        .frame(maxWidth: 700)
        .padding()
        .frame(maxWidth: .infinity)
        .disabled(session.lines.isEmpty || !chatProvider.isAvailable)
    }

    private func sendChatMessage() {
        guard chatVM.canSend else { return }
        Task { await chatVM.send(session: session, context: modelContext) }
    }
}
