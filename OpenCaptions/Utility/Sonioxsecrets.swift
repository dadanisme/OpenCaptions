//
//  Sonioxsecrets.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 02/04/26.
//



import Foundation

enum SonioxSecrets {
    /// Soniox Speech-to-Text API Key, read from Info.plist (set via .xcconfig).
    static var sonioxAPIKey: String {
        guard
            let apiKey = Bundle.main.infoDictionary?["SONIOX_API_KEY"] as? String
        else {
            fatalError(
                "SONIOX_API_KEY not found in Info.plist. Make sure it is set in the .xcconfig file."
            )
        }
        return apiKey
    }
}
