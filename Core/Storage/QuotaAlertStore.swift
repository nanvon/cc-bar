import Foundation

/// 独立串行 I/O；prepared 原子保存返回后，协调器才可向系统发送。
actor QuotaAlertStore {
    enum StoreError: Error { case missing, invalid, unsupportedVersion, changedExternally }
    typealias Writer = @Sendable (Data, URL) throws -> Void
    let url: URL
    private let writer: Writer
    private var loaded = false
    private var fingerprint: Fingerprint?

    private struct Fingerprint: Equatable {
        var modified: Date?
        var size: UInt64
        var inode: UInt64
    }

    init(url: URL = QuotaAlertStore.defaultURL, writer: @escaping Writer = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.writer = writer
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CCBar/quota-alert-state.json")
    }

    func load(initialized: Bool) throws -> QuotaAlertPayload {
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard !initialized else { throw StoreError.missing }
            let empty = QuotaAlertPayload()
            try write(empty)
            loaded = true
            return empty
        }
        let data = try Data(contentsOf: url)
        // 先读取版本，避免把未来 schema 的解码错误误认为空文件。
        struct Header: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw StoreError.invalid }
        guard [1, 2].contains(header.version) else { throw StoreError.unsupportedVersion }
        var payload = try JSONDecoder().decode(QuotaAlertPayload.self, from: data)
        payload.version = 2
        try validate(payload)
        loaded = true
        fingerprint = try currentFingerprint()
        return payload
    }

    func save(_ payload: QuotaAlertPayload) throws {
        guard loaded, FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missing }
        guard try currentFingerprint() == fingerprint else { throw StoreError.changedExternally }
        try write(payload)
    }

    func rebuild(entries: [String]) throws -> QuotaAlertPayload {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // 原文件留在同目录，使用随机名，不覆盖上次备份。
            try fm.copyItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("quota-alert-state-backup-\(UUID().uuidString).json"))
        }
        var payload = QuotaAlertPayload()
        for entry in entries {
            // * 表示重建后每个窗口的首次有效观察都建基线，随后保存已观察的窗口键。
            payload.baselineEntries[QuotaAlertIdentity.digest([entry])] = ["*"]
        }
        try write(payload)
        loaded = true
        return payload
    }

    func fileSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func write(_ payload: QuotaAlertPayload) throws {
        try validate(payload)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writer(encoder.encode(payload), url)
        fingerprint = try currentFingerprint()
    }

    private func currentFingerprint() throws -> Fingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(modified: attrs[.modificationDate] as? Date,
                           size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                           inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private func validate(_ payload: QuotaAlertPayload) throws {
        guard payload.version == 2 else { throw StoreError.unsupportedVersion }
        func digest(_ text: String) -> Bool {
            text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func windowKey(_ key: String) -> Bool {
            ["fiveHour", "weekly"].contains(key) || (key.hasPrefix("limit:") && digest(String(key.dropFirst(6))))
        }
        for (key, state) in payload.accounts {
            guard key == state.identity.key, digest(key), digest(state.identity.accountDigest),
                  state.identity.userDigest.map(digest) ?? true else { throw StoreError.invalid }
            for (kind, record) in state.windows {
                guard windowKey(kind), record.lastSeenAt.timeIntervalSince1970.isFinite,
                      record.alertedThreshold.map({ QuotaAlertPreferences.validThreshold($0) == $0 }) ?? true,
                      record.submission == nil || record.alertedThreshold != nil,
                      record.anchor.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw StoreError.invalid }
            }
        }
        for (entry, windows) in payload.baselineEntries {
            guard digest(entry), windows.allSatisfy({ $0 == "*" || windowKey($0) }) else { throw StoreError.invalid }
        }
    }
}
