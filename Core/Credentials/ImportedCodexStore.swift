import Foundation
import Security
import os

// MARK: - ImportedCodexStore
//
// 持久化"其他 Codex 账号"。
// - 元数据 → Application Support/CCBar/imported_codex_accounts.json (原子写,版本号兜底)。
// - Token 三件套 → macOS Keychain,service = ImportedCodexStore.keychainService,
//   account = account_id;value 为 JSON {access,refresh,id}。
// 用 SecItem 直接读写本进程自己的 Keychain 条目,不弹用户授权(与读 Claude/Codex CLI 凭据的
// `/usr/bin/security` 通道完全分离)。

nonisolated struct ImportedCodexTokens: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

enum ImportedCodexStore {
    nonisolated static let keychainService = "com.cc-bar.codex.imported"
    nonisolated private static let fileName = "imported_codex_accounts.json"
    nonisolated private static let bundleDirectory = "CCBar"
    nonisolated private static let tokenWriteLock = OSAllocatedUnfairLock()

    // MARK: - 元数据 (JSON)

    nonisolated private struct Payload: Codable, Equatable {
        var version: Int = 1
        var accounts: [ImportedCodexAccount] = []
    }

    nonisolated static func loadAll() -> [ImportedCodexAccount] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == 1
        else { return [] }
        return payload.accounts
    }

    nonisolated static func saveAll(_ accounts: [ImportedCodexAccount]) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(accounts: accounts))
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Token (Keychain)

    nonisolated static func loadTokens(accountId: String) -> ImportedCodexTokens? {
        var query = baseQuery(account: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let tokens = try? JSONDecoder().decode(ImportedCodexTokens.self, from: data)
        else { return nil }
        return tokens
    }

    nonisolated static func saveTokens(_ tokens: ImportedCodexTokens, accountId: String) throws {
        try tokenWriteLock.withLock {
            try writeTokens(tokens, accountId: accountId, allowInsert: true)
        }
    }

    nonisolated static func replaceTokens(
        _ tokens: ImportedCodexTokens, matching expected: ImportedCodexTokens, accountId: String
    ) throws -> Bool {
        try tokenWriteLock.withLock {
            guard loadTokens(accountId: accountId) == expected else { return false }
            try writeTokens(tokens, accountId: accountId, allowInsert: false)
            return true
        }
    }

    nonisolated private static func writeTokens(
        _ tokens: ImportedCodexTokens, accountId: String, allowInsert: Bool
    ) throws {
        let data = try JSONEncoder().encode(tokens)

        // 先尝试 update,失败再 add — 经典的 upsert 模式。
        var attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let updateStatus = SecItemUpdate(
            baseQuery(account: accountId) as CFDictionary,
            attributesToUpdate as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound || !allowInsert {
            throw KeychainError.unexpected(updateStatus)
        }

        var addQuery = baseQuery(account: accountId)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpected(addStatus)
        }
    }

    /// 镜像主账号时只在内容变化后写 Keychain，避免每轮额度刷新重复 SecItemUpdate。
    @discardableResult
    nonisolated static func saveTokensIfChanged(
        _ tokens: ImportedCodexTokens,
        accountId: String
    ) throws -> Bool {
        if loadTokens(accountId: accountId) == tokens { return false }
        try saveTokens(tokens, accountId: accountId)
        return true
    }

    nonisolated static func deleteTokens(accountId: String) {
        tokenWriteLock.withLock {
            _ = SecItemDelete(baseQuery(account: accountId) as CFDictionary)
        }
    }

    private nonisolated static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpected(OSStatus)

        var description: String {
            switch self {
            case .unexpected(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "keychain: \(msg)"
            }
        }
    }
}
