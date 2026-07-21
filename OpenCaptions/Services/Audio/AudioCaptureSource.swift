//
//  AudioCaptureSource.swift
//  OgmoMac
//
//  The audio-source abstraction the transcription pipeline streams from. The
//  microphone (`MacAudioService`, AVAudioEngine tap), system audio
//  (`SystemAudioTapCaptureService`, Core Audio process tap), and the mixed source
//  (`MixedAudioCaptureService`) all conform, emitting the SAME 16 kHz / mono /
//  Float32 `AudioFrame`s — so `MacTranscriptionViewModel`'s chunking / Soniox-send
//  / pause-resume machinery stays source-agnostic.
//
//  Selecting a source is a `UserDefaults`-backed choice surfaced in the transport
//  pill; the `AudioSource` enum + factory are the single seam each source type
//  plugs into.
//

import AVFoundation

/// A single audio frame (16 kHz, mono, Float32) and its capture timestamp.
struct AudioFrame {
    let buffer: AVAudioPCMBuffer
    let timestamp: AVAudioTime
}

/// A live capture source that yields unified 16 kHz / mono / Float32 frames.
///
/// `start()` is `async` to accommodate ScreenCaptureKit's asynchronous setup;
/// the mic path just marks its (synchronous) body `async`. `pause()` is a
/// SOFT pause: it stops delivering frames but must NOT `finish()` the stream,
/// so a resume can keep feeding the same Soniox socket.
protocol AudioCaptureSource: AnyObject {
    /// Fired when capture is interrupted mid-session and cannot continue (mic:
    /// input device/route change; system audio: SCStream stopped / permission
    /// revoked). The owner fails the session. Generalizes what the mic path
    /// previously exposed as `onConfigurationChange`.
    var onInterruption: (() -> Void)? { get set }

    /// Begin capturing and return the frame stream. Throws if the source cannot
    /// start (no input device, screen-recording denied, converter failure).
    func start() async throws -> AsyncStream<AudioFrame>

    /// Stop capturing and release resources (finishes the stream).
    func stop()

    /// Soft-pause: stop delivering frames but keep the stream open.
    func pause()

    /// Resume after `pause()`. Throwing so the owner can fail the session if the
    /// source refuses to restart.
    func resume() throws
}

/// A user-selectable capture source, surfaced in the transport-pill picker.
/// `rawValue` is persisted in `UserDefaults`. `.microphoneAndSystem` is the
/// mixed source (a plain mic + system audio summed; software echo cancellation).
enum AudioSource: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case microphoneAndSystem

    var id: String { rawValue }

    var label: String {
        switch self {
        case .microphone:         return "Microphone"
        case .systemAudio:        return "System Audio"
        case .microphoneAndSystem: return "Microphone + System Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone:         return "mic"
        case .systemAudio:        return "speaker.wave.2"
        case .microphoneAndSystem: return "waveform.badge.mic"
        }
    }

    /// Whether starting this source needs Microphone (TCC) access. (System-audio
    /// capture via a process tap has no preflight — the OS prompts on the first
    /// capture start — so there's no matching pre-start gate for it.)
    var requiresMicrophone: Bool {
        self == .microphone || self == .microphoneAndSystem
    }

    /// Whether this source captures other apps' audio — i.e. there's a source app
    /// to attribute transcript lines to. Mic-only never has one. Gates the
    /// source-app activity monitor (see `SystemAudioActivityMonitor`).
    var capturesSystemAudio: Bool {
        self == .systemAudio || self == .microphoneAndSystem
    }
}

/// Builds the concrete capture source for a selected `AudioSource`. The single
/// place source kinds map to services — a future mixed source is one case here.
enum AudioCaptureSourceFactory {
    static func make(_ kind: AudioSource) -> any AudioCaptureSource {
        switch kind {
        case .microphone:         return MacAudioService()
        case .systemAudio:        return SystemAudioTapCaptureService()
        case .microphoneAndSystem: return MixedAudioCaptureService()
        }
    }
}
