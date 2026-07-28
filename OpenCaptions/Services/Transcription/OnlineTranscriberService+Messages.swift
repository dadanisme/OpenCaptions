//
//  OnlineTranscriberService+Messages.swift
//  OpenCaptions
//
//  WebSocket receive loop and Soniox message/token parsing for
//  `OnlineTranscriberService`.
//

import Foundation

extension OnlineTranscriberService {

    // MARK: - Private Methods

    /// Continuously receives messages from the WebSocket connection.
    /// Handles both binary data and text messages, parsing them as JSON.
    func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                // Connection failed or was closed
                print("❌ receiveLoop error: \(error)")

                self.onError?(.receiveLoopEnded(underlying: error))
                self.signalDisconnect()
                return

            case .success(let message):
                // Handle both data and string message formats
                if case .data(let d) = message {
                    self.handleMessageData(d)
                } else if case .string(let str) = message {
                    if let d = str.data(using: .utf8) {
                        self.handleMessageData(d)
                    }
                }

                // Continue receiving messages
                self.receiveLoop()
            }
        }
    }

    /// Parses received JSON data and extracts transcription tokens.
    /// - Parameter data: JSON data received from the WebSocket
    private func handleMessageData(_ data: Data) {
        lastTokenTime = Date()

        // Parse JSON response
        guard
            let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return
        }

        // Check for error responses. Soniox closes the socket right after one, so
        // this used to reach the user only as the generic "Connection lost" that the
        // close then triggered — the actual reason (a rejected config, an oversized
        // `context`, quota) was printed and dropped. Reporting it lets the view model
        // fail the session with Soniox's own message; because `failSession` is
        // guarded on `isRunning || isPaused`, the close's generic failure that
        // follows is a no-op and this more specific message is what the user sees.
        if let errorCode = obj["error_code"] as? Int {
            let errorMessage =
                obj["error_message"] as? String ?? "No error message provided"
            print("❌ Transcription service error code: \(errorCode)")
            print("❌ Error message: \(errorMessage)")
            onError?(.provider(code: errorCode, message: errorMessage))
            return
        }

        // Check if transcription has finished
        if let finished = obj["finished"] as? Bool, finished {
            return
        }

        // Process token array if present
        if let arr = obj["tokens"] as? [[String: Any]] {
            var finals: [Token] = []
            var partial: [Token] = []

            for t in arr {
                // Extract text content
                guard let text = t["text"] as? String else {
                    continue
                }

                // Skip Soniox control tokens (not real transcription text)
                if text == "<fin>" { continue }

                // `<end>` is Soniox's endpoint marker: keep it as an endpoint
                // signal (empty text) rather than transcription content.
                if text == "<end>" {
                    let endpointToken = Token(
                        text: "",
                        isFinal: true,
                        speaker: -1,
                        isEndpoint: true,
                        start_ms: -1,
                        end_ms: -1
                    )
                    finals.append(endpointToken)
                    continue
                }

                // Extract speaker ID with multiple type handling
                // The speaker field can come as Int, NSNumber, or String from JSON
                let speakerValue: Int
                if let speakerNum = t["speaker"] as? Int {
                    speakerValue = speakerNum
                } else if let speakerNum = t["speaker"] as? NSNumber {
                    speakerValue = speakerNum.intValue
                } else if let speakerNum = t["speaker"] as? String,
                    let intValue = Int(speakerNum)
                {
                    speakerValue = intValue
                } else {
                    speakerValue = -1
                }

                // Create token with extracted data
                let tok = Token(
                    text: text,
                    isFinal: (t["is_final"] as? Bool) ?? false,
                    speaker: speakerValue,
                    isEndpoint: false,
                    start_ms: (t["start_ms"] as? Int) ?? 0,
                    end_ms: (t["end_ms"] as? Int) ?? 0
                )

                // Categorize as final or partial result
                if tok.isFinal {
                    finals.append(tok)
                } else {
                    partial.append(tok)
                }
            }

            // Notify callback if we have any tokens
            if !finals.isEmpty || !partial.isEmpty {
                self.onTokens?(finals, partial)
            }
        }
    }
}
