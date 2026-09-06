import Foundation

// MARK: - UpdateChecker（GitHub 发布检查）
//
// 数据源(两级降级,均为公开仓库匿名访问):
//   1. 版本清单 `https://github.com/{owner}/{repo}/releases/latest/download/version.json`
//      —— 由 release workflow 随 DMG 一起上传的静态资产,走 302 + CDN,**不占用 GitHub API 额度**。
//   2. Releases API `GET /repos/{owner}/{repo}/releases/latest` —— 兜底路径。
//      匿名 API 限 60 次/小时/**IP**,共享出口 IP(公司网络 / NAT / 代理)下极易被其他程序耗光,
//      所以只作为清单不可用(如清单尚未随该 release 发布)时的备选,不作为主路。
//
// 版本号来自 release tag(`vX.Y.Z`),与 project.pbxproj 的 MARKETING_VERSION / Info.plist 的
// CFBundleShortVersionString 对应。只做按需检查,不做轮询。
//
// 只负责告知与跳转下载页(Release page),不做自动下载/安装——工程是 ad-hoc 签名、
// 未公证,自动替换会被 Gatekeeper 拦截,且覆盖 /Applications 中的安装有风险。
//
// 见 docs/技术实现.md "更新检查" 一节。

enum UpdateChecker {
    /// 仓库大小写与 README 中徽章一致;如日后换仓库只需改这两处。
    static let repoOwner = "nanvon"
    static let repoName = "cc-bar"

    /// 由 GitHub 重定向到最新 release 的下载页。
    static let releasePageURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!

    /// 主路:随 release 上传的静态版本清单,`releases/latest/download/<asset>` 是稳定端点。
    static let versionManifestURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/version.json")!

    /// 兜底:Releases API(受匿名限流影响)。
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

    struct ReleaseInfo: Equatable, Sendable {
        /// tag 原名,如 `v1.0.2`。
        let tag: String
        let htmlURL: URL?
    }

    /// 检查更新时可区分展示的失败原因。
    enum CheckError: Error {
        /// GitHub 匿名 API 额度用尽(403 + `x-ratelimit-remaining: 0`,或 429)。
        case rateLimited
        case badResponse(status: Int)
    }

    /// 拉取最新 release 信息:先读静态版本清单,不可用时回退 Releases API。
    /// 任何网络 / 解码错误都抛出,调用方负责状态展示。
    static func fetchLatestRelease() async throws -> ReleaseInfo {
        do {
            return try await fetchFromManifest()
        } catch {
            // 清单缺失(旧 release 未附带)、网络抖动等一律回退 API;失败原因以 API 那次为准,
            // 这样限流才能被识别为 .rateLimited 而不是被清单的错误掩盖。
            return try await fetchFromAPI()
        }
    }

    /// 读取静态 `version.json`。字段见 .github/workflows/release.yml。
    static func fetchFromManifest() async throws -> ReleaseInfo {
        var request = URLRequest(url: versionManifestURL)
        request.timeoutInterval = 10
        // 资产带 CDN 缓存头,忽略本地缓存以免刚发布的版本读到旧清单。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CheckError.badResponse(status: http.statusCode)
        }

        struct Manifest: Decodable {
            let tag: String
            let page: URL?
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return ReleaseInfo(tag: manifest.tag, htmlURL: manifest.page)
    }

    /// 读取 Releases API(兜底路径)。403/429 归一化为 `.rateLimited`,便于文案区分。
    static func fetchFromAPI() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if isRateLimited(http) {
                throw CheckError.rateLimited
            }
            throw CheckError.badResponse(status: http.statusCode)
        }

        struct Payload: Decodable {
            let tagName: String?
            let htmlURL: URL?
            private enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ReleaseInfo(tag: payload.tagName ?? "", htmlURL: payload.htmlURL)
    }

    /// GitHub 用 403 + `x-ratelimit-remaining: 0` 表示额度耗尽,二次限流用 429。
    static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 429 { return true }
        guard response.statusCode == 403 else { return false }
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
        return remaining == "0"
    }

    /// 判断 tag(`vX.Y.Z`)是否比当前版本新。任一格式无法解析时按「不更新」处理,避免误报。
    static func isNewer(tag: String, than currentVersion: String) -> Bool {
        guard let new = numericComponents(of: tag), let cur = numericComponents(of: currentVersion) else {
            return false
        }
        let count = max(new.count, cur.count)
        for i in 0..<count {
            let a = i < new.count ? new[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 把版本字符串解析为数字分量:`v1.0.2` / `1.0` → [1, 0, 2]。
    /// 前缀 `v` 忽略;分量带预发布后缀时保留其数字前缀并截断后续分量
    /// (`1.0.2-beta.1` → [1, 0, 2]);首段取不出数字返回 nil。
    static func numericComponents(of version: String) -> [Int]? {
        var clean = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("v") || clean.hasPrefix("V") {
            clean.removeFirst()
        }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let head = leadingNumber(of: first) else { return nil }

        var result = [head.value]
        // 首段就带后缀(如 `1-beta.2`)时,后面的分量属于预发布标识,不再计入版本号。
        guard head.isPure else { return result }
        for part in parts.dropFirst() {
            guard let component = leadingNumber(of: part) else { break }
            result.append(component.value)
            if !component.isPure { break }
        }
        return result
    }

    /// 取分量的前导十进制数字:`2` → (2, 纯数字),`2-beta` → (2, 带后缀),`beta` / `` → nil。
    private static func leadingNumber(of part: Substring) -> (value: Int, isPure: Bool)? {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        guard let value = Int(digits) else { return nil }
        return (value, digits.count == part.count)
    }
}
