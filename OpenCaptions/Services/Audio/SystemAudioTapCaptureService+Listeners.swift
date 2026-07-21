//
//  SystemAudioTapCaptureService+Listeners.swift
//  OpenCaptions
//
//  Mid-session interruption detection for process-tap capture — the equivalent
//  of the old SCK `SCStreamDelegate.didStopWithError`. A process tap's aggregate
//  wraps the CURRENT default output device, so when the default output changes
//  (headphones plugged, device switched, sample-rate renegotiation) the tap goes
//  stale. We surface that as an interruption; the owner fails the session while
//  keeping the transcript — consistent with how the mic path treats a route
//  change (this target has no hot rebuild / reconnection).
//

import CoreAudio
import Foundation

extension SystemAudioTapCaptureService {

    /// Address of the system-wide default-output-device property.
    private var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Start listening for default-output-device changes → `onInterruption`.
    /// Installed after a successful start, so aggregate creation can't false-trip it.
    func installOutputDeviceListener() {
        var address = defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onInterruption?()
        }
        outputDeviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block
        )
    }

    /// Remove the listener (keyed on the retained block) during teardown.
    func removeOutputDeviceListener() {
        guard let block = outputDeviceListener else { return }
        var address = defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block
        )
        outputDeviceListener = nil
    }
}
