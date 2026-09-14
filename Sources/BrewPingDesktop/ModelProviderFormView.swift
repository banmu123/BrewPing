import BrewPingCore
import SwiftUI

// ─── 添加 / 编辑供应商表单 ────────────────────────────────────────────────────
//
// 对齐 Windows `model-config-card.tsx` 的表单区：
//   预设厂商下拉（按 category 分组）→ 名称 / Base URL / API Key / 模型 /
//   协议格式 / 鉴权方式 / Base URL 已是完整端点 / 备注 → 生效端点预览
//   → 「拉取模型」+ 预设模型 chips → 保存 / 取消。
//
// 归属（agentId）在新建时由调用方按当前 tab 传入，**创建即锁定**（与 Windows 一致：
// 后端更新时会强制保留原 agentId），因此表单里只做只读提示，不提供切换。

struct ModelProviderFormView: View {
    @ObservedObject private var i18n = I18n()
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ModelProviderConfig
    @State private var selectedPreset = ""
    @State private var fetching = false
    @State private var fetchError: String?

    private let catalog: [ProviderCatalogEntry]
    private let isNew: Bool
    private let onSave: (ModelProviderConfig) -> Void
    private let onCancel: () -> Void

    init(
        draft: ModelProviderConfig,
        catalog: [ProviderCatalogEntry],
        isNew: Bool,
        onSave: @escaping (ModelProviderConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.catalog = catalog
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? i18n.t(.mpAdd) : i18n.t(.mpEdit))
                .font(LatteFont.sm.weight(.medium))
                .foregroundStyle(Latte.foreground)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if isNew { presetSection }
                    field(i18n.t(.mpName)) {
                        TextField(i18n.t(.mpNamePlaceholder), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    field(i18n.t(.mpBaseUrl)) {
                        TextField(i18n.t(.mpBaseUrlPlaceholder), text: $draft.baseUrl)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    field(i18n.t(.mpApiKey)) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField(i18n.t(.mpApiKeyPlaceholder), text: $draft.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            if !isNew {
                                Text(i18n.t(.mpApiKeyKeepHint))
                                    .font(LatteFont.xs)
                                    .foregroundStyle(Latte.mutedForeground)
                            }
                        }
                    }
                    field(i18n.t(.mpModel)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField(i18n.t(.mpModelPlaceholder), text: Binding(
                                    get: { draft.model ?? "" },
                                    set: { draft.model = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()

                                Button(fetching ? i18n.t(.mpFetching) : i18n.t(.mpFetchModels)) {
                                    Task { await fetchModels() }
                                }
                                .buttonStyle(LatteButtonStyle(variant: .outline))
                                .font(LatteFont.xs)
                                .disabled(fetching)
                            }
                            if !modelSuggestions.isEmpty {
                                FlowRow(spacing: 4) {
                                    ForEach(modelSuggestions, id: \.self) { model in
                                        Button {
                                            draft.model = model
                                        } label: {
                                            Text(verbatim: model)
                                                .font(.system(size: 10, design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Latte.muted))
                                                .foregroundStyle(Latte.foreground)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if let fetchError {
                                Text(verbatim: fetchError)
                                    .font(LatteFont.xs)
                                    .foregroundStyle(Latte.destructive)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        field(i18n.t(.mpApiFormat)) {
                            Picker("", selection: $draft.apiFormat) {
                                Text(i18n.t(.mpFormatAnthropic)).tag("anthropic")
                                Text(i18n.t(.mpFormatOpenaiChat)).tag("openai_chat")
                                Text(i18n.t(.mpFormatOpenaiResponses)).tag("openai_responses")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        field(i18n.t(.mpAuthStyle)) {
                            Picker("", selection: $draft.authStyle) {
                                Text(i18n.t(.mpAuthAuto)).tag("auto")
                                Text(i18n.t(.mpAuthBearer)).tag("bearer")
                                Text(i18n.t(.mpAuthXApiKey)).tag("x-api-key")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                    Toggle(isOn: $draft.isFullUrl) {
                        Text(i18n.t(.mpIsFullUrl))
                            .font(LatteFont.xs)
                    }
                    .toggleStyle(.checkbox)

                    field(i18n.t(.mpEffectiveEndpoint)) {
                        Text(verbatim: ProviderCatalog.previewEndpoint(
                            baseUrl: draft.baseUrl, apiFormat: draft.apiFormat, isFullUrl: draft.isFullUrl
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Latte.mutedForeground)
                        .textSelection(.enabled)
                    }

                    field(i18n.t(.mpNotes)) {
                        TextField("", text: Binding(
                            get: { draft.notes ?? "" },
                            set: { draft.notes = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 420)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(i18n.t(.mpCancel)) {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(LatteButtonStyle(variant: .outline))
                Button(i18n.t(.mpSave)) {
                    onSave(draft)
                }
                .buttonStyle(LatteButtonStyle(variant: .primary))
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Latte.background)
    }

    // MARK: - 预设

    private var presetSection: some View {
        field(i18n.t(.mpVendorPick)) {
            Picker("", selection: $selectedPreset) {
                Text(i18n.t(.mpPresetCategoryCustom)).tag("")
                ForEach(groupedCatalog, id: \.category) { group in
                    Section(categoryLabel(group.category)) {
                        ForEach(group.entries) { entry in
                            Text(verbatim: i18n.locale == .zh ? entry.displayName : entry.name)
                                .tag(entry.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: selectedPreset) { value in
                applyPreset(value)
            }
        }
    }

    private var groupedCatalog: [(category: String, entries: [ProviderCatalogEntry])] {
        let groups = Dictionary(grouping: catalog.filter { $0.category != "custom" }, by: \.category)
        return groups
            .map { (category: $0.key, entries: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ProviderCatalog.categoryOrder($0.category) < ProviderCatalog.categoryOrder($1.category) }
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "official": return i18n.t(.mpPresetCategoryOfficial)
        case "cn_official": return i18n.t(.mpPresetCategoryCnOfficial)
        case "aggregator": return i18n.t(.mpPresetCategoryAggregator)
        case "third_party": return i18n.t(.mpPresetCategoryThirdParty)
        default: return i18n.t(.mpPresetCategoryCustom)
        }
    }

    /// 选中预设 → 填充名称 / baseURL / 协议 / 鉴权 / 模型；**不动已有 Key**。
    private func applyPreset(_ id: String) {
        guard let entry = catalog.first(where: { $0.id == id }) else { return }
        draft.name = i18n.locale == .zh ? entry.displayName : entry.name
        draft.baseUrl = entry.baseUrl
        draft.apiFormat = entry.apiFormat
        draft.authStyle = entry.authStyle
        if draft.model == nil || draft.model?.isEmpty == true {
            draft.model = entry.models.first
        }
        fetchError = nil
    }

    /// 可选模型：预设自带的固定清单（拉取失败时也能手动点选）。
    private var modelSuggestions: [String] {
        guard let entry = catalog.first(where: { $0.id == selectedPreset }) else { return [] }
        return entry.models
    }

    // MARK: - 拉取模型

    private func fetchModels() async {
        guard let entry = ProviderCatalog.matchByBaseUrl(draft.baseUrl) else {
            fetchError = i18n.t(.mpFetchUnsupported)
            return
        }
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let ids = try await DesktopCommands.fetchProviderModels(
                providerId: entry.id, apiKey: draft.apiKey
            )
            guard !ids.isEmpty else {
                fetchError = i18n.t(.mpFetchFailed)
                return
            }
            if draft.model == nil || draft.model?.isEmpty == true {
                draft.model = ids.first
            }
        } catch {
            let message = error.localizedDescription
            if message.contains("401") || message.contains("403") {
                fetchError = i18n.t(.mpInvalidKey)
            } else if message.contains("missing api key") {
                fetchError = i18n.t(.mpFetchNeedKey)
            } else if message.contains("fetchUnsupported") {
                fetchError = i18n.t(.mpFetchUnsupported)
            } else {
                fetchError = "\(i18n.t(.mpFetchFailed)): \(message)"
            }
        }
    }

    // MARK: - 小工具

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
