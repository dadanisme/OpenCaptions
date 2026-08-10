//
//  APIKeyStore.swift
//  OpenCaptions
//
//  Runtime-entered Soniox/OpenRouter API keys (Settings → API Keys), so a
//  prebuilt .app the user didn't compile themselves can still be handed real
//  credentials without a rebuild. Kept in the Keychain rather than
//  UserDefaults since these are real secrets, not preferences — each is its
//  own generic-password item under this app's private (non-shared)
//  `keychain-access-groups` entry; see OpenCaptions.entitlements.
//
//  A runtime value here always takes priority over the Config.xcconfig-
//  supplied Info.plist value — see `SonioxSecrets.sonioxAPIKey` and
//  `SummaryService+OpenRouter.apiKey()`, the two places that layer the two
//  sources together. This type only knows about the Keychain half.
//

import Foundation
import Security

enum APIKeyStore {
    enum Key: String {
        case soniox = "SonioxAPIKey"
        case openRouter = "OpenRouterAPIKey"
    }

    private static let service = "com.muhammadramdan.OpenCaptions.apikeys"

    /// The stored key, or `nil` when unset (never returns an empty string —
    /// `write` deletes the item instead of storing one).
    static func read(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Stores `value` (trimmed of surrounding whitespace/newlines — a common
    /// copy-paste artifact that would otherwise corrupt the WebSocket config
    /// frame or the `Authorization` header this key ends up in), or deletes
    /// the item when the trimmed value is empty — an empty field means "use
    /// the build-time key, if any," not "use an empty key." Returns whether
    /// the value is now actually persisted, so a caller can tell a save
    /// apart from a silent Keychain failure.
    @discardableResult
    static func write(_ key: Key, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return true
        }
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus != errSecSuccess else { return true }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            print("⚠️ API key store: failed to save \(key.rawValue) (status \(addStatus))")
            return false
        }
        return true
    }

    static func delete(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
