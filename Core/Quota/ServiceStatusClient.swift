import Foundation
import SwiftUI

// MARK: - ServiceStatus 模型与抓取
//
// 复用 Statuspage.io 公开接口:
// - OpenAI    https://status.openai.com/api/v2/status.json
// - Anthropic https://status.claude.com/api/v2/status.json
// - Cursor    https://status.cursor.com/api/v2/status.json
// 返回 status.indicator 字符串枚举:none / minor / major / critical / maintenance,
// 解析失败统一归为 .unknown。
//
// 见 docs/技术实现.md "服务状态" 一节。

enum ServiceStatusIndicator: String, Sendable, Codable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    /// 弹出窗口 / 悬浮窗使用的圆点颜色;`.unknown` 由 UI 自行决定是否显示。
    var dotColor: Color {
        switch self {
        case .none: return .green
        case .minor: return .yellow
        case .major: return .orange
        case .critical: return .red
        case .maintenance: return .blue
        case .unknown: return .gray
        }
    }

    /// 默认中英文标签,在 UI 没有 description 时用作 tooltip。
    @MainActor
    var label: String {
        switch self {
        case .none: return tr("All systems normal", "运行正常")
        case .minor: return tr("Minor issue", "轻微故障")
        case .major: return tr("Major issue", "重大故障")
        case .critical: return tr("Critical outage", "严重故障")
        case .maintenance: return tr("Maintenance", "维护中")
        case .unknown: return tr("Status unknown", "状态未知")
        }
    }
}

struct ServiceStatus: Sendable, Equatable {
    var indicator: ServiceStatusIndicator
    var description: String?
    var updatedAt: Date?
    var fetchedAt: Date
}

enum ServiceStatusClient {
    nonisolated static let openAIStatusURL = URL(string: "https://status.openai.com/api/v2/status.json")!
    nonisolated static let anthropicStatusURL = URL(string: "https://status.claude.com/api/v2/status.json")!
    static let cursorStatusURL = URL(string: "https://status.cursor.com/api/v2/status.json")!

    /// 拉取 Statuspage.io status.json 并解析为 ServiceStatus;
    /// 任何网络 / 解码错误都抛出,调用方负责保留旧快照。
    static func fetch(from url: URL) async throws -> ServiceStatus {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = if url == anthropicStatusURL {
            try await NetworkProxy.claudeData(for: request)
        } else {
            try await NetworkProxy.data(for: request)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }
            struct Page: Decodable {
                let updatedAt: Date?
                private enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
            }
            let page: Page?
            let status: Status
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }

        let payload = try decoder.decode(Response.self, from: data)
        let indicator = ServiceStatusIndicator(rawValue: payload.status.indicator) ?? .unknown
        return ServiceStatus(
            indicator: indicator,
            description: payload.status.description,
            updatedAt: payload.page?.updatedAt,
            fetchedAt: Date()
        )
    }
}
