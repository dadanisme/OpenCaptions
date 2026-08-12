//
//  CoreAIParakeetPlugin.swift
//  CoreAIPlugin
//
//  STUB — proves the dlopen boundary end to end before the real Core AI
//  Parakeet model (apple/coreai-models' CoreAISpeech, `.parakeetTDT` bundle
//  kind) is wired in. Returns a canned transcript instead of running any
//  model. See docs/2026-08-12-macos-coreai-plugin-skeleton.md.
//

import Foundation

final class CoreAIParakeetPlugin: NSObject, CoreAITranscriptionPlugin {
    func transcribe(audioFileURL: URL, completion: @escaping (String?, Error?) -> Void) {
        // TODO(#47): replace with CoreAISpeech.SpeechRecognitionModel once the
        // exported model bundle + download flow land.
        let stubText =
            "Stub transcript from the Core AI Parakeet plugin (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) for \(audioFileURL.lastPathComponent)."
        completion(stubText, nil)
    }
}
