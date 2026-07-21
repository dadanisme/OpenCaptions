//
//  MediaAudioExtractor.swift
//  OpenCaptions
//
//  Normalizes an imported audio OR video file into the app's canonical session
//  `.m4a` (AAC-LC, 16 kHz, mono, 32 kbps — the exact format `SessionAudioRecorder`
//  writes) so imported media flows through the same transcription/playback pipeline
//  as a live recording. For video, only the audio track is read — the video is
//  discarded and never leaves the device.
//
//  Uses AVAssetReader → AVAssetWriter (not AVAudioFile, which can't open video
//  containers): the reader decodes+resamples the source audio track to 16 kHz mono
//  PCM and the writer re-encodes it to AAC. It streams at constant memory and
//  reports progress, so an hour-long lecture transcodes without loading into RAM.
//

import AVFoundation
import Foundation

/// Failures surfaced when importing an external media file.
enum MediaImportError: LocalizedError {
    /// The chosen file has no decodable audio track (e.g. a silent video).
    case noAudioTrack
    /// The reader/decoder failed to read the source audio.
    case readFailed(String)
    /// The AAC encoder / writer failed.
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "This file has no audio to transcribe."
        case .readFailed(let message):
            return "Couldn't read the audio from this file: \(message)"
        case .writeFailed(let message):
            return "Couldn't prepare the audio for transcription: \(message)"
        }
    }
}

enum MediaAudioExtractor {

    /// Transcodes `source` (audio or video) into a fresh `<uuid>.m4a` under
    /// `SessionAudioStore.directory` and returns its filename + duration in seconds.
    ///
    /// - Throws: `MediaImportError` on failure, `CancellationError` if cancelled — in
    ///   both cases the partial output file is removed before returning.
    static func extractToSessionAudio(
        source: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> (fileName: String, durationSeconds: Double) {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
            throw MediaImportError.noAudioTrack
        }
        let rawDuration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let totalSeconds = rawDuration.isFinite ? max(0, rawDuration) : 0

        let fileName = UUID().uuidString + ".m4a"
        let outputURL = SessionAudioStore.url(for: fileName)
        try? FileManager.default.removeItem(at: outputURL)

        do {
            try await transcode(track: audioTrack, from: asset, to: outputURL,
                                totalSeconds: totalSeconds, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return (fileName, totalSeconds)
    }

    // MARK: - Reader → writer pump

    /// Drives a cooperative pull loop (rather than `requestMediaDataWhenReady`, whose
    /// `@Sendable` block would fight the non-Sendable reader/writer under strict
    /// concurrency). Runs off the main actor (nonisolated async), so the tight decode
    /// loop never blocks the UI; `Task.checkCancellation()` makes it cancellable.
    private static func transcode(
        track: AVAssetTrack,
        from asset: AVAsset,
        to outputURL: URL,
        totalSeconds: Double,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Decode+resample the source track to 16 kHz mono signed-16 PCM (the reader's
        // audio converter does the resample/downmix), then AAC-encode via the writer.
        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SessionAudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw MediaImportError.readFailed("output rejected") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        // Share the recorder's exact AAC settings; add a mono channel layout, which the
        // AVAssetWriter AAC encoder requires (AVAudioFile does not, so it's added here).
        var writerSettings = SessionAudioRecorder.aacSettings
        var mono = AudioChannelLayout()
        mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        writerSettings[AVChannelLayoutKey] = Data(bytes: &mono,
                                                  count: MemoryLayout<AudioChannelLayout>.size)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw MediaImportError.writeFailed("input rejected") }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw MediaImportError.readFailed(reader.error?.localizedDescription ?? "start failed")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MediaImportError.writeFailed(writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        var lastReported = -1.0
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(nanoseconds: 5_000_000)  // 5 ms: let the encoder drain
                    continue
                }
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                guard writerInput.append(sample) else {
                    throw MediaImportError.writeFailed(writer.error?.localizedDescription ?? "append failed")
                }
                report(sample, total: totalSeconds, last: &lastReported, progress: progress)
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        try await finalize(reader: reader, writer: writer, input: writerInput)
    }

    /// Finalizes once the reader drains: distinguishes a clean finish from a
    /// cancellation or a decode failure, and closes out the AAC file accordingly.
    private static func finalize(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) async throws {
        switch reader.status {
        case .completed:
            input.markAsFinished()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting { cont.resume() }
            }
            guard writer.status == .completed else {
                throw MediaImportError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
            }
        case .cancelled:
            input.markAsFinished()
            writer.cancelWriting()
            throw CancellationError()
        default:
            writer.cancelWriting()
            throw MediaImportError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }
    }

    /// Forwards coarse progress to the main actor, throttled to ~1% steps so a long
    /// file doesn't flood the UI with updates.
    private static func report(
        _ sample: CMSampleBuffer,
        total: Double,
        last: inout Double,
        progress: @escaping @MainActor (Double) -> Void
    ) {
        guard total > 0 else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard seconds.isFinite else { return }
        let fraction = min(1, max(0, seconds / total))
        guard fraction - last >= 0.01 else { return }
        last = fraction
        Task { @MainActor in progress(fraction) }
    }
}
