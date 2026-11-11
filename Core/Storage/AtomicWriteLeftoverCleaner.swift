import Foundation

/// 清理 Foundation 原子写（`Data.write(to:options: .atomic)`）留下的临时文件。
///
/// 原子写先写 `<目标文件名>.sb-<8 位十六进制>-<6 位字符>`，写完再改名成目标文件；
/// 进程在写入过程中被终止时，这个临时文件会留在目录里，App 不会再读它。
///
/// 规则保守：只看给定目录的直接子项，不递归；只删文件名匹配上述格式、是普通文件、
/// 且修改时间早于 `minimumAge` 的项。其余文件（`.bak-*`、`imported-usage-*`、
/// `quarantine/` 等）一律不动。
nonisolated enum AtomicWriteLeftoverCleaner {
    /// 正在进行的原子写只会留下刚创建的临时文件，24 小时足以避开。
    static let minimumAge: TimeInterval = 24 * 60 * 60

    /// 生产目录：`Application Support/CCBar` 与其下的 `usage-history`。
    static func productionDirectories() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = support.appendingPathComponent("CCBar", isDirectory: true)
        return [root, root.appendingPathComponent("usage-history", isDirectory: true)]
    }

    /// 删除过期的原子写临时文件，返回已删除的文件。单个文件删除失败不影响其他文件。
    @discardableResult
    static func removeStaleLeftovers(
        in directories: [URL],
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var removed: [URL] = []
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            ) else { continue }
            for url in entries where isLeftoverName(url.lastPathComponent) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= minimumAge
                else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    removed.append(url)
                } catch {
                    AppLog.warn(.persistence, "atomic-write leftover remove failed file=\(url.lastPathComponent) error=\(Redact.error(error))")
                }
            }
        }
        return removed
    }

    /// 文件名是否形如 `<目标文件名>.sb-<8 位十六进制>-<6 位字母数字>`。
    static func isLeftoverName(_ name: String) -> Bool {
        guard let marker = name.range(of: ".sb-", options: .backwards),
              marker.lowerBound > name.startIndex
        else { return false }
        let suffix = name[marker.upperBound...]
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let token = parts[0]
        let random = parts[1]
        return token.count == 8
            && token.allSatisfy { $0.isASCII && $0.isHexDigit }
            && random.count == 6
            && random.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
