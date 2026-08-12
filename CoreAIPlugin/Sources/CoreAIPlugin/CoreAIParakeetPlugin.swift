//
//  CoreAIParakeetPlugin.swift
//  CoreAIPlugin
//
//  Real transcription via john-rocky/coreai-kit's `KitTranscriber`, which owns
//  Parakeet's model download/caching itself (Application Support/CoreAIKit/Models) —
//  no export/hosting pipeline of our own. Decodes the file to 16 kHz mono Float32
//  first (mirroring NemotronPostSessionEngine's AVAudioConverter pattern on the app
//  side, incl. the `supplied`-flag exhaustion guard), since KitTranscriber takes raw
//  samples, not a file URL. See docs/2026-08-12-macos-coreai-plugin-skeleton.md.
//

import AVFoundation
import CoreAIKit
import Foundation

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
            let transcriber = try await KitTranscriber(catalog: "parakeet-tdt-0.6b-v3")
            let result = try await transcriber.transcribe(samples: samples)
            completion(result.text, nil)
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
