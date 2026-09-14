import { useMemo, useState } from "react";
import { Loader2, Plus, X } from "lucide-react";
import type { ClaudeProviderEntry, ClaudeTierEntry } from "../../api/types";
import { Button } from "../ui/button";
import { useI18n, type DictKey } from "../../i18n";
import { cn } from "../../lib/utils";

// ─── Claude Code「厂商配置」表单（对标 cc-switch）────────────────────────────
//
// 保存后由后端**整体覆盖**写进 ~/.claude/settings.json（env 段），用户免手改。
// 表单只收集信息 + 做本地校验，**不做任何 IO**。
//
// Claude Code 的 settings.json 只有一份配置（不像 opencode 能装多个 provider），
// 所以这里是「编辑当前这一份」而不是「列表 + 多卡片」。
//
// 三档模型映射（sonnet / opus / haiku）：Claude Code 用它们把内置档位
// 映射到厂商真实型号。留空 = 不写这组键，Claude Code 用官方默认。

const inputCls =
  "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";
const fieldLabelCls = "mb-0.5 block text-[10px] text-muted-foreground";

/** 三档固定顺序（UI 展示顺序，也决定写文件的顺序）。 */
const TIERS: { key: string; labelKey: DictKey; placeholder: string }[] = [
  { key: "sonnet", labelKey: "cl.sonnet", placeholder: "claude-sonnet-4-6" },
  { key: "opus", labelKey: "cl.opus", placeholder: "claude-opus-4-6" },
  { key: "haiku", labelKey: "cl.haiku", placeholder: "claude-haiku-4-5" },
];

/** 新建空白配置草稿。 */
export function emptyClaudeProvider(): ClaudeProviderEntry {
  return {
    name: "",
    baseURL: "",
    apiKey: "",
    tiers: TIERS.map((t) => ({ tier: t.key, model: "", name: "" })),
    otherKeys: [],
  };
}

/** 补齐三档（读回的配置可能只填了部分档位）。 */
export function normalizeClaudeTiers(entry: ClaudeProviderEntry): ClaudeProviderEntry {
  const byTier = new Map(entry.tiers.map((t) => [t.tier, t]));
  return {
    ...entry,
    tiers: TIERS.map(
      (t) => byTier.get(t.key) ?? { tier: t.key, model: "", name: "" },
    ),
  };
}

export function ClaudeProviderForm({
  value,
  busy,
  error,
  onChange,
  onCancel,
  onSave,
}: {
  value: ClaudeProviderEntry;
  busy: boolean;
  error: string | null;
  onChange: (next: ClaudeProviderEntry) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  const { t } = useI18n();
  const [advancedOpen, setAdvancedOpen] = useState(false);

  const baseError = useMemo(() => {
    const base = value.baseURL.trim();
    if (!base) return t("oc.errBaseRequired");
    if (!/^https?:\/\//i.test(base)) return t("oc.errBaseScheme");
    return null;
  }, [value.baseURL, t]);

  const canSave = !busy && !baseError;

  const tierOf = (key: string): ClaudeTierEntry =>
    value.tiers.find((x) => x.tier === key) ?? { tier: key, model: "", name: "" };

  const setTier = (key: string, patch: Partial<ClaudeTierEntry>) => {
    const exists = value.tiers.some((x) => x.tier === key);
    const tiers = exists
      ? value.tiers.map((x) => (x.tier === key ? { ...x, ...patch } : x))
      : [...value.tiers, { tier: key, model: "", name: "", ...patch }];
    onChange({ ...value, tiers });
  };

  return (
    <div className="flex flex-col gap-2.5 rounded-md border border-border p-2.5">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-foreground">
          {t("cl.editTitle")}
        </span>
        <button
          type="button"
          className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
          onClick={onCancel}
          title={t("mp.cancel")}
        >
          <X size={13} />
        </button>
      </div>

      <div className="rounded-md bg-muted/60 px-2 py-1 text-[10px] leading-relaxed text-muted-foreground">
        {t("cl.formHint")}
      </div>

      <div>
        <span className={fieldLabelCls}>{t("cl.providerName")}</span>
        <input
          className={inputCls}
          placeholder={t("oc.namePlaceholder")}
          value={value.name}
          onChange={(e) => onChange({ ...value, name: e.target.value })}
        />
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.baseUrl")}</span>
        <input
          className={cn(inputCls, "font-mono", baseError && "border-destructive/50")}
          placeholder={t("cl.baseUrlPlaceholder")}
          value={value.baseURL}
          onChange={(e) => onChange({ ...value, baseURL: e.target.value })}
        />
        {baseError && (
          <p className="mt-0.5 text-[10px] text-destructive">{baseError}</p>
        )}
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.apiKey")}</span>
        <input
          className={cn(inputCls, "font-mono")}
          type="password"
          autoComplete="off"
          placeholder={t("mp.apiKeyPlaceholder")}
          value={value.apiKey}
          onChange={(e) => onChange({ ...value, apiKey: e.target.value })}
        />
      </div>

      {/* 三档模型映射（ANTHROPIC_DEFAULT_<TIER>_MODEL）*/}
      <div>
        <div className="mb-1 text-[10px] text-muted-foreground">
          {t("cl.tiers")}
        </div>
        <div className="flex flex-col gap-1.5">
          {TIERS.map((tier) => {
            const cur = tierOf(tier.key);
            return (
              <div key={tier.key} className="flex items-center gap-1.5">
                <span className="w-12 shrink-0 text-[10px] text-muted-foreground">
                  {t(tier.labelKey)}
                </span>
                <input
                  className={cn(inputCls, "font-mono")}
                  placeholder={tier.placeholder}
                  value={cur.model}
                  onChange={(e) => setTier(tier.key, { model: e.target.value })}
                />
                <input
                  className={inputCls}
                  placeholder={t("oc.modelNamePlaceholder")}
                  value={cur.name}
                  onChange={(e) => setTier(tier.key, { name: e.target.value })}
                />
              </div>
            );
          })}
        </div>
        <p className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("cl.tiersHint")}
        </p>
      </div>

      {/* 高级：看哪些顶层键会被"整体覆盖"式保存一起保留 */}
      <div className="border-t border-border/70 pt-2">
        <button
          type="button"
          className="flex items-center gap-1 text-[10px] text-muted-foreground hover:text-foreground"
          onClick={() => setAdvancedOpen((v) => !v)}
        >
          {advancedOpen ? "▾" : "▸"}
          {t("mp.advanced")}
        </button>
        {advancedOpen && (
          <div className="mt-2 text-[10px] leading-relaxed text-muted-foreground/70">
            {value.otherKeys.length > 0 ? (
              <>
                <div>{t("cl.otherKeysHint")}</div>
                <div className="mt-1 font-mono break-all">
                  {value.otherKeys.join(", ")}
                </div>
              </>
            ) : (
              <div>{t("cl.otherKeysNone")}</div>
            )}
          </div>
        )}
      </div>

      {error && (
        <div className="break-all text-[10px] leading-relaxed text-destructive">
          {error}
        </div>
      )}

      <div className="flex justify-end gap-2">
        <Button
          variant="outline"
          size="sm"
          className="h-7 px-3 text-[11px]"
          disabled={busy}
          onClick={onCancel}
        >
          {t("mp.cancel")}
        </Button>
        <Button
          size="sm"
          className="h-7 px-3 text-[11px]"
          disabled={!canSave}
          onClick={onSave}
        >
          {busy && <Loader2 size={11} className="mr-1 animate-spin" />}
          {t("mp.save")}
        </Button>
      </div>
    </div>
  );
}

/** 「未配置」状态的引导卡片（点「配置厂商」进入表单）。 */
export function ClaudeProviderEmpty({
  onAdd,
  loading,
}: {
  onAdd: () => void;
  loading: boolean;
}) {
  const { t } = useI18n();
  if (loading) {
    return (
      <div className="flex items-center justify-center py-4 text-muted-foreground">
        <Loader2 size={14} className="animate-spin" />
      </div>
    );
  }
  return (
    <div className="py-3 text-center">
      <div className="text-xs text-muted-foreground">{t("cl.empty")}</div>
      <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
        {t("cl.emptyHint")}
      </div>
      <Button
        variant="outline"
        size="sm"
        className="mt-2 h-6 gap-1 px-2 text-[10px]"
        onClick={onAdd}
      >
        <Plus size={11} />
        {t("cl.configure")}
      </Button>
    </div>
  );
}
