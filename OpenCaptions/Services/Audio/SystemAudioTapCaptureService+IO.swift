//
//  SystemAudioTapCaptureService+IO.swift
//  OpenCaptions
//
//  The Core Audio tap/aggregate/IOProc half of process-tap system-audio capture:
//  builds a whole-system tap + a private aggregate device, installs the IOProc,
//  starts the device (which triggers the "Audio Recording" TCC prompt on first
//  run), and converts each callback's samples to the unified 16 kHz / mono /
//  Float32 target. Split from the lifecycle file to stay under the line limit
//  (mirrors the old SCK service's +Output split).
//

import AVFoundation
import CoreAudio
import Foundation

extension SystemAudioTapCaptureService {

    // MARK: - Build & start

    /// Create the tap + private aggregate and start the IOProc. Throws on any
    /// Core Audio failure. A permission *denial* does NOT throw — the device
    /// starts and simply yields silence until the grant is given.
    func buildAndStart() throws {
        // Whole-system mono tap, excluding our own output if we have any (so our
        // future TTS/alert sounds aren't captured back into the transcript).
        let excluded = [CoreAudioTapUtils.ownProcessObjectID()].compactMap { $0 }
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Open Captions System Audio Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // don't mute the actual speakers while tapping

        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CoreAudioError(message: "create process tap", status: status)
        }

        // Read the tap's native ASBD — correct channel count / format flags, but its
        // sample RATE is the tap's own mixer rate, which is NOT necessarily the rate
        // the aggregate IOProc delivers frames at (fixed up below).
        var asbd = try CoreAudioTapUtils.tapStreamFormat(tapID)

        // Private aggregate: default output as main sub-device + the tap as a
        // sub-tap, auto-started so the IOProc receives frames.
        let outputUID = try CoreAudioTapUtils.defaultOutputDeviceUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenCaptions-System-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw CoreAudioError(message: "create aggregate device", status: status)
        }

        // The IOProc is installed on the AGGREGATE, whose clock is its main sub-device
        // (the default OUTPUT device). Drift compensation resamples the tap's native
        // stream TO that clock, so frames arrive at the aggregate's nominal rate — e.g.
        // 44.1 kHz frames, NOT the tap's native 48 kHz. Interpreting them with the tap
        // rate over-decimates the resample and pitches the audio up ~9%. Override
        // only the sample rate (channel count / format flags are rate-independent and
        // correct); keep the tap rate if the read fails so a working 48 kHz path never
        // regresses into a hard failure. Set BEFORE the IOProc/AudioDeviceStart below,
        // so no callback ever observes an unset or stale sourceFormat.
        if let aggRate = try? CoreAudioTapUtils.nominalSampleRate(aggregateID), aggRate > 0 {
            asbd.mSampleRate = aggRate
        }
        sourceFormat = AVAudioFormat(streamDescription: &asbd)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleTapInput(inInputData)
        }
        guard status == noErr, ioProcID != nil else {
            throw CoreAudioError(message: "create IOProc", status: status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)   // triggers the prompt on first run
        guard status == noErr else {
            throw CoreAudioError(message: "start device", status: status)
        }
    }

    // MARK: - IOProc → frame

    /// Delivered on `ioQueue`. Gate on `isPaused` first (a soft pause costs
    /// nothing), wrap the no-copy buffer list, convert, and yield an owned frame.
    func handleTapInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard !isPaused, let continuation, let outputFormat, let sourceFormat,
              let source = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat, bufferListNoCopy: inInputData, deallocator: nil
              ), source.frameLength > 0,
              let converted = convert(source, to: outputFormat)
        else { return }

        continuation.yield(AudioFrame(
            buffer: converted, timestamp: AVAudioTime(hostTime: mach_absolute_time())
        ))
    }

    /// Convert a tap buffer to the 16 kHz mono Float32 target with a reused
    /// converter (rebuilt if the source format changes; `downmix` covers a stereo
    /// tap). One-shot input block + `autoreleasepool` mirror the mic path. Returns
    /// an OWNED buffer safe to hand off.
    private func convert(_ inBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = inBuffer.format
        if converter == nil || converter?.inputFormat != source {
            let made = AVAudioConverter(from: source, to: outputFormat)
            made?.downmix = true
            converter = made
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16   // +resampler slack
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return inBuffer
        }
        var conversionError: NSError?
        let result = autoreleasepool {
            converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
        }
        guard conversionError == nil, result != .error, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }
}
