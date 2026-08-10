//
//  Sonioxsecrets.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 02/04/26.
//



import Foundation

enum SonioxSecrets {
    /// Soniox Speech-to-Text API Key. Prefers the runtime value entered in
    /// Settings → API Keys (Keychain-backed, `APIKeyStore`) over the
    /// Config.xcconfig-supplied Info.plist value, so a prebuilt .app can be
    /// handed real credentials without a rebuild. `nil` when neither is
    /// set — a missing key is a normal, recoverable runtime state now, not a
    /// launch-time crash; see `MacTranscriptionViewModel.start` and
    /// `SonioxAsyncPostSessionEngine.transcribe`, the two callers.
    static var sonioxAPIKey: String? {
        if let runtime = APIKeyStore.read(.soniox) {
            return runtime
        }
        guard
            let buildTime = Bundle.main.infoDictionary?["SONIOX_API_KEY"] as? String,
            !buildTime.isEmpty
        else {
            return nil
        }
        return buildTime
    }
}
