import { useMemo } from "react";
import type { CatalogCategory, CatalogEndpoint, CatalogEntry } from "../../api/types";
import { useI18n } from "../../i18n";

// ─── 厂商预设下拉（各 CLI 专属表单共用的「选厂商 → 自动预填」控件）──────────────
//
// 背景：原先只有「转发代理」区块里的内联表单带预填下拉，四个 CLI 专属表单
// （opencode / claude / codex / pi）都要求用户手填 base_url —— 同一家厂商要
// 重复填四遍，很容易打错。这里把它抽成共用控件，四个表单各接一次。
//
// 设计约束（与后端 provider_catalog.rs 一致）：
// - 目录**只是预填模板，不是校验白名单** —— 选完仍可随意改（中转站地址千变万化）；
// - **端点按 agent 分派**（2026-09-14 对齐 cc-switch 源码实证）：同一厂商在
//   不同 agent 下 baseURL 与协议不同（/anthropic 只属于 Claude Code；Codex
//   用 OpenAI Responses 端点；OpenCode/pi 用 OpenAI 兼容端点）——onPick
//   会把「解析好的 agent 端点」一并传回，调用方无须自行挑字段；
// - `custom` 条目不预填任何值（只当作「我要自己填」的显式选择）；
// - 插值走 t()，两语言 key 由 locales.ts 的 Record 约束保证对齐。

/** 预设下拉支持的 agent 标识（与后端 AgentEndpoint.agent 逐字对齐）。 */
export type PresetAgentId = CatalogEndpoint["agent"];

/** category 分组排序权重（custom 恒最后；未识别分类居中）。 */
const CATEGORY_ORDER: Record<CatalogCategory, number> = {
  official: 0,
  cn_official: 1,
  aggregator: 2,
  third_party: 3,
  custom: 99,
};

/** 按 category 稳定分组（保持 CATALOG 内的原顺序）。 */
export function groupCatalogByCategory(
  catalog: CatalogEntry[],
): { category: CatalogCategory; entries: CatalogEntry[] }[] {
  const sorted = [...catalog].sort(
    (a, b) =>
      (CATEGORY_ORDER[a.category] ?? 50) - (CATEGORY_ORDER[b.category] ?? 50),
  );
  const groups: { category: CatalogCategory; entries: CatalogEntry[] }[] = [];
  for (const c of sorted) {
    const last = groups[groups.length - 1];
    if (last && last.category === c.category) last.entries.push(c);
    else groups.push({ category: c.category, entries: [c] });
  }
  return groups;
}

/**
 * 解析某 agent 在该厂商下的端点：优先命中 `endpoints` 表（后端按 agent
 * 分派的数据），缺失时回落顶层模板（兼容 custom / 旧数据）。
 */
export function resolvePresetEndpoint(
  entry: CatalogEntry,
  agentId: PresetAgentId,
): CatalogEndpoint {
  const hit = entry.endpoints?.find((e) => e.agent === agentId);
  if (hit) return hit;
  return { agent: agentId, baseUrl: entry.baseUrl, wireApi: "", npm: "", piApi: "" };
}

/**
 * 「选择厂商（自动预填）」下拉。
 *
 * 受控组件：`value` 是当前选中的目录 id（空串 = 还没选）。
 * 因目录只是模板，用户改完字段后 `value` 仍停在所选 id 上，这是刻意的 ——
 * 保留它才能让用户回看"我是从哪家预填的"，也便于再次切换重填。
 */
export function VendorPresetSelect({
  catalog,
  agentId,
  value,
  disabled,
  onPick,
}: {
  /** 可用的目录条目（空数组 = 不渲染控件）。 */
  catalog: CatalogEntry[];
  /** 调用方所属 agent —— 决定传回哪个端点（baseURL 与协议都按 agent 分派）。 */
  agentId: PresetAgentId;
  /** 当前选中的目录 id（"" = 未选）。 */
  value: string;
  disabled?: boolean;
  /** 用户选了某家（entry 供名称/模型等，endpoint 是该 agent 应用的端点+协议）。 */
  onPick: (entry: CatalogEntry, endpoint: CatalogEndpoint) => void;
}) {
  const { t } = useI18n();
  const grouped = useMemo(() => groupCatalogByCategory(catalog), [catalog]);

  if (catalog.length === 0) return null;

  const inputCls =
    "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";

  return (
    <div>
      <span className="mb-0.5 block text-[10px] text-muted-foreground">
        {t("mp.vendor")}
      </span>
      <select
        className={inputCls}
        value={value}
        disabled={disabled}
        onChange={(e) => {
          const entry = catalog.find((c) => c.id === e.target.value);
          if (entry) onPick(entry, resolvePresetEndpoint(entry, agentId));
        }}
      >
        <option value="">{t("mp.vendorPick")}</option>
        {grouped.map((g) => (
          <optgroup key={g.category} label={t(`mp.presetCategory.${g.category}`)}>
            {g.entries.map((c) => (
              <option key={c.id} value={c.id}>
                {c.displayName || c.name}
              </option>
            ))}
          </optgroup>
        ))}
      </select>
    </div>
  );
}
