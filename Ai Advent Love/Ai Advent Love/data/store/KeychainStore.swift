//
//  KeychainStore.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    // Keychain namespace for this app
    // Keychain namespace for this app (current)
    private let service = "AiAdventChat.LLM"

    private let legacyService = "AiAdventChat.OpenAI"

    // Provider-specific accounts
    private let groqAccount = "GROQ_API_KEY"
    private let claudeAccount = "CLAUDE_API_KEY"

    // Backward compatibility (older builds stored everything under this account)
    private let legacyAccount = "OPENAI_API_KEY"

    private func saveKey(_ key: String, account: String) throws {
        let data = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        let add: [String: Any] = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]) { $1 }

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainStore", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain save error: \(status)"
            ])
        }
    }

    private func loadKey(account: String, service: String? = nil) -> String? {
        let svc = service ?? self.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKey(account: String, service: String? = nil) {
        let svc = service ?? self.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Backward-compatible default: saves the key for Groq provider.
    func saveAPIKey(_ key: String) throws {
        try saveGroqAPIKey(key)
    }

    /// Backward-compatible default: loads the key for Groq provider.
    /// Falls back to legacy storage used by older builds.
    func loadAPIKey() -> String? {
        return loadGroqAPIKey()
    }

    /// Backward-compatible default: clears the Groq key (and legacy key if present).
    func clearAPIKey() {
        clearGroqAPIKey()
        deleteKey(account: legacyAccount)
        deleteKey(account: legacyAccount, service: legacyService)
    }

    // MARK: - Provider-specific APIs

    func saveGroqAPIKey(_ key: String) throws {
        try saveKey(key, account: groqAccount)
    }

    func loadGroqAPIKey() -> String? {
        return loadKey(account: groqAccount)
            ?? loadKey(account: legacyAccount)
            ?? loadKey(account: legacyAccount, service: legacyService)
    }

    func clearGroqAPIKey() {
        deleteKey(account: groqAccount)
    }

    func saveClaudeAPIKey(_ key: String) throws {
        try saveKey(key, account: claudeAccount)
    }

    func loadClaudeAPIKey() -> String? {
        return loadKey(account: claudeAccount)
    }

    func clearClaudeAPIKey() {
        deleteKey(account: claudeAccount)
    }

    func clearAllAPIKeys() {
        clearGroqAPIKey()
        clearClaudeAPIKey()
        deleteKey(account: legacyAccount)
        deleteKey(account: legacyAccount, service: legacyService)
    }
}
