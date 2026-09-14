import { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Loader2, RefreshCw, X } from "lucide-react";
import type { CodexProviderEntry, WireApiOption } from "../../api/types";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

// ─── Codex「添加 / 编辑厂商」表单（对标 cc-switch）──────────────────────────
//
// 保存后由后端写进 ~/.codex/config.toml 的 [model_providers.<key>]（保留注释），
// Key 走 provider 作用域的 experimental_bearer_token，**不碰 auth.json**。
// 表单只收集信息 + 做本地校验，**不做任何 IO**。
//
// 校验规则与后端 services/codex_provider_config.rs 逐条对齐：
// - provider key：`^[a-z0-9]+(-[a-z0-9]+)*$`，且不得是 Codex 保留 id
//   （openai / ollama / lmstudio —— 覆盖它们 Codex 会拒载整份配置）；
// - 名称必填（Codex 拒载无名表）；base_url 必填且 http(s)；wire_api 二选一。

const inputCls =
  "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";
const fieldLabelCls = "mb-0.5 block text-[10px] text-muted-foreground";

/** Codex 保留 provider id（与后端 RESERVED_PROVIDER_IDS 一致）。 */
const RESERVED_IDS = ["openai", "ollama", "lmstudio"];

/** 与后端 `slugify_provider_key` 同规则。 */
export function slugifyCodexKey(name: string): string {
  let out = "";
  let prevDash = false;
  for (const ch of name) {
    const c = ch.toLowerCase();
    if (/[a-z0-9]/.test(c)) {
      out += c;
      prevDash = false;
    } else if (!prevDash && out.length > 0) {
      out += "-";
      prevDash = true;
    }
  }
  out = out.replace(/-+$/, "");
  return out || "provider";
}

/** 与后端 `is_valid_provider_key` 同规则。 */
export function isValidCodexKey(key: string): boolean {
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(key);
}

/** 新建空白厂商草稿。 */
export function emptyCodexProvider(defaultWireApi: string): CodexProviderEntry {
  return {
    id: "",
    name: "",
    baseURL: "",
    wireApi: defaultWireApi || "chat",
    apiKey: "",
    model: "",
    active: false,
  };
}

export function CodexProviderForm({
  value,
  wireApis,
  existingIds,
  busy,
  isEdit,
  onChange,
  onCancel,
  onSave,
  onFetchModels,
  fetchingModels,
  fetchErr,
}: {
  value: CodexProviderEntry;
  wireApis: WireApiOption[];
  /** 已存在的厂商 key（查重用；编辑时排除自身）。 */
  existingIds: string[];
  busy: boolean;
  /** true = 编辑既有厂商（key 不可改）。 */
  isEdit: boolean;
  onChange: (next: CodexProviderEntry) => void;
  onCancel: () => void;
  onSave: () => void;
  /** 拉取上游模型清单（可选能力；失败不影响手动填写）。 */
  onFetchModels: () => void;
  fetchingModels: boolean;
  fetchErr: string | null;
}) {
  const { t } = useI18n();
  const [keyDirty, setKeyDirty] = useState(isEdit);
  const [advancedOpen, setAdvancedOpen] = useState(false);

  const keyConflict = useMemo(
    () => existingIds.some((id) => id === value.id) && !isEdit,
    [existingIds, value.id, isEdit],
  );

  const keyError = !value.id.trim()
    ? t("oc.errKeyRequired")
    : !isValidCodexKey(value.id.trim())
      ? t("oc.errKeyFormat")
      : RESERVED_IDS.includes(value.id.trim())
        ? t("cx.errKeyReserved")
        : keyConflict
          ? t("oc.errKeyTaken")
          : null;

  const baseError = useMemo(() => {
    const base = value.baseURL.trim();
    if (!base) return t("oc.errBaseRequired");
    if (!/^https?:\/\//i.test(base)) return t("oc.errBaseScheme");
    return null;
  }, [value.baseURL, t]);

  const canSave =
    !busy && !keyError && !baseError && value.name.trim().length > 0;

  const handleNameChange = (name: string) => {
    if (!keyDirty && !isEdit) {
      onChange({ ...value, name, id: slugifyCodexKey(name) });
    } else {
      onChange({ ...value, name });
    }
  };

  return (
    <div className="flex flex-col gap-2.5 rounded-md border border-border p-2.5">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-foreground">
          {isEdit ? t("cx.editTitle") : t("cx.addTitle")}
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
        {t("cx.formHint")}
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.name")}</span>
        <input
          className={inputCls}
          placeholder={t("oc.namePlaceholder")}
          value={value.name}
          onChange={(e) => handleNameChange(e.target.value)}
        />
      </div>

      <div>
        <span className={fieldLabelCls}>{t("oc.key")}</span>
        <input
          className={cn(inputCls, "font-mono", keyError && "border-destructive/50")}
          placeholder={t("cx.keyPlaceholder")}
          value={value.id}
          disabled={isEdit}
          onChange={(e) => {
            setKeyDirty(true);
            onChange({ ...value, id: e.target.value });
          }}
        />
        <p
          className={cn(
            "mt-0.5 text-[10px] leading-relaxed",
            keyError ? "text-destructive" : "text-muted-foreground/70",
          )}
        >
          {keyError ?? t("oc.keyHint")}
        </p>
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.baseUrl")}</span>
        <input
          className={cn(inputCls, "font-mono", baseError && "border-destructive/50")}
          placeholder={t("cx.baseUrlPlaceholder")}
          value={value.baseURL}
          onChange={(e) => onChange({ ...value, baseURL: e.target.value })}
        />
        {baseError && (
          <p className="mt-0.5 text-[10px] text-destructive">{baseError}</p>
        )}
      </div>

      <div>
        <span className={fieldLabelCls}>{t("cx.wireApi")}</span>
        <select
          className={inputCls}
          value={value.wireApi}
          onChange={(e) => onChange({ ...value, wireApi: e.target.value })}
        >
          {wireApis.map((w) => (
            <option key={w.value} value={w.value}>
              {w.label}
            </option>
          ))}
        </select>
        <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("cx.wireApiHint")}
        </p>
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
        <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("cx.apiKeyHint")}
        </p>
      </div>

      <div>
        <div className="mb-1 flex items-center justify-between">
          <span className="text-[10px] text-muted-foreground">
            {t("cx.model")}
          </span>
          <Button
            variant="outline"
            size="sm"
            className="h-6 px-2 text-[10px]"
            disabled={fetchingModels || !value.baseURL.trim()}
            title={t("oc.fetchModels")}
            onClick={onFetchModels}
          >
            {fetchingModels ? (
              <Loader2 size={10} className="mr-1 animate-spin" />
            ) : (
              <RefreshCw size={10} />
            )}
            {fetchingModels ? t("mp.fetching") : t("oc.fetchModels")}
          </Button>
        </div>
        {fetchErr && (
          <p className="mb-1 text-[10px] leading-relaxed text-warning">
            {fetchErr}
          </p>
        )}
        <input
          className={cn(inputCls, "font-mono")}
          placeholder={t("cx.modelPlaceholder")}
          value={value.model}
          onChange={(e) => onChange({ ...value, model: e.target.value })}
        />
        <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("cx.modelHint")}
        </p>
      </div>

      <div className="border-t border-border/70 pt-2">
        <button
          type="button"
          className="flex items-center gap-1 text-[10px] text-muted-foreground hover:text-foreground"
          onClick={() => setAdvancedOpen((v) => !v)}
        >
          {advancedOpen ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
          {t("mp.advanced")}
        </button>
        {advancedOpen && (
          <p className="mt-2 text-[10px] leading-relaxed text-muted-foreground/70">
            {t("cx.advancedHint")}
          </p>
        )}
      </div>

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
