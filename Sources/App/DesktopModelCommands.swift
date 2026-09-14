import Foundation

// ─── 桌面命令面：模型配置（对齐 Windows 端同名 tauri 命令）──────────────────────
//
// 与 Windows `lib.rs` 的命令逐条对应（函数名 = 命令名驼峰化）：
//   get_model_providers   → modelProviders()
//   save_model_provider   → saveModelProvider(_:)
//   delete_model_provider → deleteModelProvider(id:)
//   switch_model_provider → switchModelProvider(id:agentId:)
//   set_model_proxy       → setModelProxy(enabled:port:)
//   set_model_failover    → setModelFailover(enabled:)
//   get_provider_catalog  → providerCatalog()
//   fetch_provider_models → fetchProviderModels(providerId:apiKey:)
//
// CLI 接管（get/set_cli_takeover）依赖本地转发代理，属 Phase 2，本轮未接入。

extension DesktopCommands {

    // MARK: - 供应商 CRUD

    public static func modelProviders() -> ModelProvidersInfo {
        ModelProviderStore.shared.info()
    }

    public static func saveModelProvider(_ draft: ModelProviderConfig) throws -> ModelProvidersInfo {
        try ModelProviderStore.shared.save(draft)
    }

    public static func deleteModelProvider(id: String) -> ModelProvidersInfo {
        ModelProviderStore.shared.delete(id: id)
    }

    public static func switchModelProvider(id: String, agentId: String) -> ModelProvidersInfo {
        ModelProviderStore.shared.switchCurrent(id: id, agentId: agentId)
    }

    // MARK: - 代理开关（运行态在 Phase 2 由代理模块提供）

    public static func setModelProxy(enabled: Bool, port: Int) -> ModelProvidersInfo {
        ModelProviderStore.shared.setProxy(enabled: enabled, port: port)
    }

    public static func setModelFailover(enabled: Bool) -> ModelProvidersInfo {
        ModelProviderStore.shared.setFailover(enabled: enabled)
    }

    // MARK: - 厂商目录

    public static func providerCatalog() -> [ProviderCatalogEntry] {
        ProviderCatalog.all
    }

    /// 拉取上游模型清单（OpenAI `GET /models`）。
    ///
    /// 复用静态目录按 baseURL 匹配拿 `models_url` —— 匹配不到由调用方提示手填，
    /// **不猜端点、不硬拼路径**（与 Windows `fetch_provider_models` 同语义）。
    public static func fetchProviderModels(providerId: String, apiKey: String?) async throws -> [String] {
        guard let entry = ProviderCatalog.all.first(where: { $0.id == providerId }),
              !entry.modelsUrl.isEmpty,
              let url = URL(string: entry.modelsUrl) else {
            throw ModelProviderFetchError.unsupported
        }
        let key = apiKey?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !key.isEmpty else { throw ModelProviderFetchError.missingKey }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // macOS 端没有 iOS 那套 BrewPingHTTP 封装（那是 iOS/Auth 专用），
        // 这里是直连上游厂商的公开端点，不需要配对鉴权 → 直接用 URLSession。
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ModelProviderFetchError.http(status)
        }
        return Self.parseModelList(data)
    }

    /// 解析 OpenAI 风格 `/models` 响应（纯函数；失败返回空数组，不抛错）。
    static func parseModelList(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [Any] else { return [] }
        var ids: [String] = []
        for item in list {
            if let dict = item as? [String: Any], let id = dict["id"] as? String, !id.isEmpty {
                ids.append(id)
            } else if let id = item as? String, !id.isEmpty {
                ids.append(id)
            }
        }
        return ids
    }
}

public enum ModelProviderFetchError: LocalizedError {
    case unsupported
    case missingKey
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "fetchUnsupported"
        case .missingKey: return "missing api key"
        case .http(let status): return "HTTP \(status)"
        }
    }
}
