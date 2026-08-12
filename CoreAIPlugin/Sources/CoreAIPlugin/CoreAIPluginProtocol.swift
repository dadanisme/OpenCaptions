//
//  CoreAIPluginProtocol.swift
//  CoreAIPlugin
//
//  Keep this declaration BYTE-FOR-BYTE in sync with the app-side copy at
//  OpenCaptions/Services/Retranscription/CoreAI/CoreAIPluginProtocol.swift —
//  see that file's header for why there are two copies instead of one shared
//  file, and for why BOTH the protocol's own `@objc(CoreAITranscriptionPlugin)`
//  name and the method's `@objc(...)` selector need to be explicit and
//  identical on both sides.
//

import Foundation

@objc(CoreAITranscriptionPlugin) public protocol CoreAITranscriptionPlugin: NSObjectProtocol {
    /// Transcribes the audio file at `audioFileURL` and calls `completion`
    /// exactly once, with either the transcript text or an error — never both nil.
    @objc(transcribeAudioFileURL:completion:)
    func transcribe(audioFileURL: URL, completion: @escaping (String?, Error?) -> Void)
}
