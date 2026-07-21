//
//  OnlineTranscriberService+ConnectionHealth.swift
//  unmute
//
//  Disconnect signaling and zombie-connection detection for
//  `OnlineTranscriberService`.
//

import Foundation

extension OnlineTranscriberService {

    // MARK: - Disconnect Signal

    /// Signals to the ViewModel that this connection is dead and needs replacement.
    /// Guarded to fire only once per service lifecycle.
    func signalDisconnect() {
        guard !hasSignaledDisconnect else { return }
        hasSignaledDisconnect = true
        // Mark for resume(): if the ViewModel drops this signal because the
        // session is paused (isRunning == false), resume() still detects the
        // dead connection via needsReconnect and performs a reconnect.
        needsReconnect = true
        stopZombieCheck()
        stopKeepalive()
        onConnectionStateChange?(.disconnected)
    }

    // MARK: - Zombie Detection

    func startZombieCheck() {
        stopZombieCheck()
        lastTokenTime = Date()
        lastLoudAudioTime = nil

        zombieCheckTimer = Timer.scheduledTimer(
            withTimeInterval: TranscriptionConstants.zombieTimeoutSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.checkForZombie()
        }
        if let timer = zombieCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopZombieCheck() {
        zombieCheckTimer?.invalidate()
        zombieCheckTimer = nil
    }

    func reportAudioLevel(_ level: Float) {
        guard level > TranscriptionConstants.zombieAudioLevelThreshold else { return }
        lastLoudAudioTime = Date()
        if let lastToken = lastTokenTime,
           Date().timeIntervalSince(lastToken) > TranscriptionConstants.zombieTimeoutSeconds {
            print("⚠️ Zombie connection detected")
            onError?(.zombieConnection)
            signalDisconnect()
        }
    }

    func markTokensReceived() {
        lastTokenTime = Date()
    }

    private func checkForZombie() {
        guard let lastToken = lastTokenTime,
              Date().timeIntervalSince(lastToken) > TranscriptionConstants.zombieTimeoutSeconds else {
            return
        }
        // The zombie premise — "audio is flowing, so tokens must flow back" — only
        // holds when speech-level audio was actually streaming. A silent room with no
        // tokens is healthy, not dead, so require recent loud audio before tearing down.
        guard let lastLoud = lastLoudAudioTime,
              Date().timeIntervalSince(lastLoud) <= TranscriptionConstants.zombieTimeoutSeconds else {
            return
        }
        print("⚠️ Zombie connection detected (timer check)")
        onError?(.zombieConnection)
        signalDisconnect()
    }
}
