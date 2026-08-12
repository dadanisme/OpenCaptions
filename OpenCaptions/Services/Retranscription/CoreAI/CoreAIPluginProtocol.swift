//
//  CoreAIPluginProtocol.swift
//  OpenCaptions
//
//  The dlopen boundary to libCoreAIPlugin.dylib — a sibling SPM package (see
//  ../../../../../CoreAIPlugin/Package.swift) pinned to macOS 27.0, the floor
//  Apple's Core AI / `coreai-models` requires, 13 majors above this app's
//  14.4+ target. SwiftPM enforces a package's platform floor on the WHOLE
//  consuming target, so OpenCaptions can never `import CoreAISpeech` directly
//  — this plain @objc protocol is the only thing shared between the two
//  independently-compiled binaries; CoreAIPluginLoader bridges across it via
//  the Objective-C runtime's selector dispatch, not shared Swift metadata.
//
//  Keep this declaration BYTE-FOR-BYTE in sync with the plugin-side copy at
//  CoreAIPlugin/Sources/CoreAIPlugin/CoreAIPluginProtocol.swift. Two explicit
//  @objc(...) names are what makes that safe: the one on the METHOD pins its
//  selector, but a plain `@objc protocol` also registers itself with the ObjC
//  runtime under a MODULE-QUALIFIED name (e.g. "OpenCaptions.CoreAITranscriptionPlugin"
//  vs. "CoreAIPlugin.CoreAITranscriptionPlugin") — the app and plugin are two
//  independently-compiled modules, so without the explicit name on the
//  PROTOCOL itself too, `instance as? CoreAITranscriptionPlugin` fails at
//  runtime even though the method selector matches (confirmed empirically:
//  dlopen/dlsym/calling the factory all succeed in isolation via a plain C
//  harness, and only the Swift-side protocol cast was the failure point).
//

import Foundation

@objc(CoreAITranscriptionPlugin) protocol CoreAITranscriptionPlugin: NSObjectProtocol {
    /// Transcribes the audio file at `audioFileURL` and calls `completion`
    /// exactly once, with either the transcript text or an error — never both nil.
    @objc(transcribeAudioFileURL:completion:)
    func transcribe(audioFileURL: URL, completion: @escaping (String?, Error?) -> Void)
}
