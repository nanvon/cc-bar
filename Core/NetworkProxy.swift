import Foundation
import Network
import os

// MARK: - 网络代理
//
// cc-bar 的常规出网请求走 `NetworkProxy.data(for:)`（见 docs/技术实现.md「网络代理」）。
// 全局代理有两种模式：
// - 跟随系统：直接用 `URLSession.shared`，读 macOS 系统代理，与加入代理设置前完全一致。
// - 手动：用户填写的 HTTP / SOCKS5 代理。
// 手动模式下代理不可用时直接报错，不回退直连或系统代理：带着账号凭据的请求
// 换一个出口发出，服务端看到的就是同一账号在两个 IP 上同时使用。
// Claude 请求用 `claudeData(for:)`，始终要求显式配置代理。

nonisolated enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case manual

    var id: String { rawValue }
}

nonisolated enum ProxyType: String, CaseIterable, Identifiable, Sendable {
    case http
    case socks5

    var id: String { rawValue }
}

nonisolated struct ProxyEndpoint: Sendable, Hashable {
    var type: ProxyType
    var host: String
    var port: Int

    /// 界面与日志里显示的地址，如 `127.0.0.1:7890`。
    var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

nonisolated enum ProxyUnavailableReason: Sendable, Hashable {
    /// Claude 沿用全局代理时，全局必须设为手动。
    case claudeManualRequired
    /// 手动模式下地址或端口没填。
    case manualIncomplete
    /// 端口不在 1～65535。
    case invalidPort
    /// 地址带 `/`、空白，或带了端口（含冒号但不是 IPv6 地址）。
    case invalidHost
}

nonisolated enum ProxyResolution: Sendable, Hashable {
    case system
    case proxy(ProxyEndpoint)
    case unavailable(ProxyUnavailableReason)
}

/// 代理已开启但用不了时抛出；`QuotaError.from(transport:)` 把它归为 `.network(.proxyUnavailable)`。
nonisolated struct ProxyUnavailableError: Error, Sendable {
    let reason: ProxyUnavailableReason
}

nonisolated enum NetworkProxy {
    /// 与 `SettingsStore` 共用的 key：取数在后台线程直接读 UserDefaults，不经过主线程的 SettingsStore。
    enum Keys {
        static let mode = "ccbar.settings.proxyMode"
        static let type = "ccbar.settings.proxyType"
        static let host = "ccbar.settings.proxyHost"
        static let port = "ccbar.settings.proxyPort"
        static let useDedicatedClaudeProxy = "ccbar.settings.useDedicatedClaudeProxy"
        static let claudeType = "ccbar.settings.claudeProxyType"
        static let claudeHost = "ccbar.settings.claudeProxyHost"
        static let claudePort = "ccbar.settings.claudeProxyPort"
    }

    private struct State: Sendable {
        var endpoint: ProxyEndpoint?
        var session: URLSession?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let claudeState = OSAllocatedUnfairLock(initialState: State())

    // MARK: 请求

    /// 替代 `URLSession.shared.data(for:)`。`session` 只给需要注入会话的调用方用。
    static func data(for request: URLRequest, session: URLSession? = nil) async throws -> (Data, URLResponse) {
        let session = try session ?? currentSession()
        return try await session.data(for: request)
    }

    static func currentSession() throws -> URLSession {
        try session(for: resolve())
    }

    private static func session(for resolution: ProxyResolution) throws -> URLSession {
        switch resolution {
        case .system:
            return .shared
        case .proxy(let endpoint):
            return session(for: endpoint, state: state, makeSession: makeSession)
        case .unavailable(let reason):
            throw ProxyUnavailableError(reason: reason)
        }
    }

    static func claudeData(
        for request: URLRequest, using proxy: ProxyResolution = resolveClaude()
    ) async throws -> (Data, URLResponse) {
        let session = try claudeSession(for: proxy)
        return try await session.data(for: request)
    }

    private static func claudeSession(for resolution: ProxyResolution) throws -> URLSession {
        switch resolution {
        case .system:
            throw ProxyUnavailableError(reason: .claudeManualRequired)
        case .unavailable(let reason):
            throw ProxyUnavailableError(reason: reason)
        case .proxy(let endpoint):
            return session(for: endpoint, state: claudeState, makeSession: makeClaudeSession)
        }
    }

    /// 用设置点击时的配置测试，不发送账号凭据。
    static func testConnection(using resolution: ProxyResolution, forClaude: Bool) async -> Result<Void, QuotaError> {
        var request = forClaude ? ClaudeQuotaClient.usageRequest(timeout: 10)
            : URLRequest(url: ServiceStatusClient.openAIStatusURL, timeoutInterval: 10)
        if forClaude {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
        }
        do {
            let (data, response) = if forClaude {
                try await claudeData(for: request, using: resolution)
            } else {
                try await session(for: resolution).data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { return .failure(.decode("non-http")) }
            if forClaude, !ClaudeQuotaClient.isUnauthenticatedUsageResponse(http, data: data) {
                return .failure(.http(http.statusCode, String(data: data, encoding: .utf8) ?? ""))
            }
            return .success(())
        } catch {
            return .failure(.from(transport: error))
        }
    }

    // MARK: 解析配置

    static func resolve() -> ProxyResolution {
        resolve(defaults: .standard)
    }

    private static func resolve(defaults: UserDefaults) -> ProxyResolution {
        let mode = defaults.string(forKey: Keys.mode).flatMap(ProxyMode.init(rawValue:)) ?? .system
        switch mode {
        case .system:
            return .system
        case .manual:
            return manualResolution(defaults: defaults, typeKey: Keys.type, hostKey: Keys.host, portKey: Keys.port)
        }
    }

    static func resolveClaude() -> ProxyResolution {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Keys.useDedicatedClaudeProxy) {
            return manualResolution(defaults: defaults, typeKey: Keys.claudeType,
                                    hostKey: Keys.claudeHost, portKey: Keys.claudePort)
        }
        return claudeUsingGlobal(resolve(defaults: defaults))
    }

    static func claudeUsingGlobal(_ global: ProxyResolution) -> ProxyResolution {
        if case .system = global { return .unavailable(.claudeManualRequired) }
        return global
    }

    private static func manualResolution(
        defaults: UserDefaults, typeKey: String, hostKey: String, portKey: String
    ) -> ProxyResolution {
        let type = defaults.string(forKey: typeKey).flatMap(ProxyType.init(rawValue:)) ?? .http
        let host = defaults.string(forKey: hostKey) ?? ""
        let port = defaults.integer(forKey: portKey)
        return manualResolution(type: type, host: host, port: port)
    }

    static func manualResolution(type: ProxyType, host: String, port: Int) -> ProxyResolution {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, port != 0 else { return .unavailable(.manualIncomplete) }
        guard !host.contains("/"),
              !host.contains(where: \.isWhitespace),
              !host.contains(":") || isIPv6Literal(host)
        else { return .unavailable(.invalidHost) }
        guard (1...65535).contains(port) else { return .unavailable(.invalidPort) }
        return .proxy(ProxyEndpoint(type: type, host: host, port: port))
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    // MARK: 会话

    /// 同一地址复用一个会话；地址变了就换新会话，旧会话等进行中的请求跑完再释放。
    private static func session(
        for endpoint: ProxyEndpoint,
        state: OSAllocatedUnfairLock<State>,
        makeSession: (ProxyEndpoint) -> URLSession
    ) -> URLSession {
        state.withLock { current in
            if let session = current.session, current.endpoint == endpoint { return session }
            current.session?.finishTasksAndInvalidate()
            let session = makeSession(endpoint)
            current.endpoint = endpoint
            current.session = session
            return session
        }
    }

    private static func makeSession(_ endpoint: ProxyEndpoint) -> URLSession {
        var proxy: [String: Any] = [:]
        switch endpoint.type {
        case .http:
            proxy[kCFNetworkProxiesHTTPEnable as String] = 1
            proxy[kCFNetworkProxiesHTTPProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesHTTPPort as String] = endpoint.port
            proxy[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxy[kCFNetworkProxiesHTTPSProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesHTTPSPort as String] = endpoint.port
        case .socks5:
            proxy[kCFNetworkProxiesSOCKSEnable as String] = 1
            proxy[kCFNetworkProxiesSOCKSProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesSOCKSPort as String] = endpoint.port
        }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = proxy
        return URLSession(configuration: configuration)
    }

    private static func makeClaudeSession(_ endpoint: ProxyEndpoint) -> URLSession {
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!
        )
        var proxy: ProxyConfiguration
        switch endpoint.type {
        case .http:
            proxy = ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)
        case .socks5:
            proxy = ProxyConfiguration(socksv5Proxy: proxyEndpoint)
        }
        proxy.allowFailover = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy]
        return URLSession(configuration: configuration)
    }

    // MARK: 子进程

    /// `agy` 子进程的环境变量。代理不可用或为 SOCKS5 时返回 nil，调用方跳过 CLI。
    static func subprocessEnvironment(base: [String: String]) -> [String: String]? {
        switch resolve() {
        case .system:
            return base
        case .unavailable:
            return nil
        case .proxy(let endpoint):
            guard endpoint.type == .http else { return nil }
            var environment = base
            let url = "http://\(endpoint.address)"
            for key in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] {
                environment[key] = url
            }
            for key in ["ALL_PROXY", "all_proxy"] {
                environment.removeValue(forKey: key)
            }
            return environment
        }
    }
}
