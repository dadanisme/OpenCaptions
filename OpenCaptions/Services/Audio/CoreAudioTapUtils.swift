//
//  CoreAudioTapUtils.swift
//  OgmoMac
//
//  Small Core Audio HAL helpers shared by the process-tap system-audio capture
//  (`SystemAudioTapCaptureService`): reading object properties, translating our
//  own PID to an audio process object (to exclude our output from the tap), the
//  default output device's UID (the aggregate must wrap a real device), and a
//  tap's native stream format. Kept separate so the capture service stays focused.
//
//  Process taps require macOS 14.4+ — callers guard with `@available`.
//

import CoreAudio
import Foundation

/// A Core Audio failure carrying the offending `OSStatus` for logging.
struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus
    var errorDescription: String? { "\(message) (OSStatus \(status))" }
}

enum CoreAudioTapUtils {

    /// Read a fixed-size property value of type `T` from an audio object.
    static func property<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ initial: T,
        _ label: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(message: "read \(label) failed", status: status) }
        return value
    }

    /// The audio process object for a PID, or `nil` if the process has never
    /// produced audio (so there's nothing to exclude from a tap).
    static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    /// Our own audio process object (to exclude our output from the tap), if any.
    static func ownProcessObjectID() -> AudioObjectID? {
        processObjectID(forPID: getpid())
    }

    /// The default output device's UID — the aggregate's main sub-device.
    static func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioObjectID = try property(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            AudioObjectID(kAudioObjectUnknown),
            "default output device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError(message: "no default output device", status: kAudioHardwareBadDeviceError)
        }
        let uid: CFString = try property(
            deviceID, kAudioDevicePropertyDeviceUID, "" as CFString, "device UID"
        )
        return uid as String
    }

    /// A process tap's native capture format (typically 48 kHz Float32). NOTE: this
    /// is the tap's OWN rate; once the tap is a sub-tap of an aggregate, its frames
    /// are delivered to the IOProc at the AGGREGATE's rate — read that separately
    /// with `nominalSampleRate(_:)` (see #304).
    static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try property(
            tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription(), "tap format"
        )
    }

    /// A device's nominal sample rate (Hz). For an aggregate device this is its
    /// master clock, inherited from the main sub-device — i.e. the actual rate the
    /// IOProc delivers frames at, regardless of a sub-tap's own native rate (#304).
    static func nominalSampleRate(_ deviceID: AudioObjectID) throws -> Double {
        let rate: Float64 = try property(
            deviceID, kAudioDevicePropertyNominalSampleRate, Float64(0), "nominal sample rate"
        )
        return Double(rate)
    }

    // MARK: - Audio-activity monitoring (source-app attribution)

    /// Every audio process object known to the HAL. A process appears here once
    /// it has touched audio; the list changes as apps start/stop playing.
    static func processObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CoreAudioError(message: "process list size", status: status) }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { throw CoreAudioError(message: "process list data", status: status) }
        return ids
    }

    /// Whether a process object currently has at least one active OUTPUT stream
    /// (i.e. it's playing audio right now).
    static func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        let running: UInt32 = (try? property(
            processObject, kAudioProcessPropertyIsRunningOutput, UInt32(0), "is-running-output"
        )) ?? 0
        return running != 0
    }

    /// A process object's owning PID, or nil if unavailable. Used to walk up to
    /// the responsible app when the process itself is a helper.
    static func pid(for processObject: AudioObjectID) -> pid_t? {
        let value: pid_t = (try? property(
            processObject, kAudioProcessPropertyPID, pid_t(-1), "process pid"
        )) ?? -1
        return value > 0 ? value : nil
    }

    /// A process object's bundle id, or nil if it has none (some helper / system
    /// processes don't). Read as a CFString, exactly like `defaultOutputDeviceUID`.
    static func bundleID(for processObject: AudioObjectID) -> String? {
        guard let cf: CFString = try? property(
            processObject, kAudioProcessPropertyBundleID, "" as CFString, "bundle id"
        ) else { return nil }
        let value = cf as String
        return value.isEmpty ? nil : value
    }
}
