//
//  CoreAIParakeetPlugin.swift
//  CoreAIPlugin
//
//  Real transcription via john-rocky/coreai-kit's `KitParakeetModel`, which owns
//  Parakeet's model download/caching itself (Application Support/CoreAIKit/Models) —
//  no export/hosting pipeline of our own. Decodes the file to 16 kHz mono Float32
//  first (mirroring NemotronPostSessionEngine's AVAudioConverter pattern on the app
//  side, incl. the `supplied`-flag exhaustion guard), since the model takes raw
//  samples, not a file URL. See docs/2026-08-12-macos-coreai-plugin-skeleton.md.
//
//  CHUNKED (found empirically, re-transcribing a real ~1h session): unlike the
//  official apple/coreai-models export (--dynamic), CoreAIKit's own Parakeet bundle
//  is fixed-bucket only — ParakeetMelPreprocessor.logMel silently pads-or-TRIMS
//  every call's samples to the encoder's declared bucket (~28.84s for this catalog
//  entry's pinned revision, 2885 mel frames * 160 hop / 16 kHz), the same class of
//  silent-truncation bug #44's spike found in Apple's own static export. One call
//  per file was losing everything past the first ~29 seconds. `chunkDurationSeconds`
//  stays comfortably under that bucket; re-verify against the pinned catalog
//  revision (coreai-kit/catalog.json, "parakeet-tdt-0.6b-v3") if it ever changes.
//

import AVFoundation
import CoreAIKit
import Foundation

private let sampleRate = 16_000
private let chunkDurationSeconds: Double = 26

final class CoreAIParakeetPlugin: NSObject, CoreAITranscriptionPlugin {
    func transcribe(audioFileURL: URL, completion: @escaping @Sendable (String?, Error?) -> Void) {
        Task {
            await Self.runTranscription(audioFileURL: audioFileURL, completion: completion)
        }
    }

    private static func runTranscription(
        audioFileURL: URL, completion: @escaping @Sendable (String?, Error?) -> Void
    ) async {
        do {
            let samples = try decodeMono16kHz(audioFileURL)
            // Loaded once and reused across chunks — KitParakeetModel is documented
            // "serial use (one transcription at a time)"; reconstructing it per chunk
            // would also reload/recompile the three graphs on every call.
            let model = try await KitParakeetModel(catalog: "parakeet-tdt-0.6b-v3")

            let chunkSamples = Int(chunkDurationSeconds * Double(sampleRate))
            var texts: [String] = []
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSamples, samples.count)
                let result = try await model.transcribe(samples: Array(samples[offset..<end]))
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { texts.append(text) }
                offset = end
            }
            completion(texts.joined(separator: " "), nil)
        } catch {
            completion(nil, error)
        }
    }

    private static func decodeMono16kHz(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw CoreAIPluginError.audioConversionSetupFailed
        }

        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CoreAIPluginError.audioConversionSetupFailed }
        try file.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { throw CoreAIPluginError.audioConversionSetupFailed }

        // `supplied` stops the converter re-invoking this block for more input once the
        // whole file has already been handed over — without it the converter spins asking
        // for more data forever since we only ever have the one buffer.
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil, status != .error else {
            throw conversionError ?? CoreAIPluginError.audioConversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

enum CoreAIPluginError: Error {
    case audioConversionSetupFailed
    case audioConversionFailed
}
