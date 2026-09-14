import { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Loader2, Plus, RefreshCw, X } from "lucide-react";
import type {
  NpmPackageOption,
  OpenCodeModelEntry,
  OpenCodeProviderEntry,
} from "../../api/types";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

// ─── OpenCode「添加 / 编辑厂商」表单（对标 cc-switch）──────────────────────────
//
// 保存后由后端写进本机 opencode 的 opencode.json（`provider.<key>` 段），
// 用户免手改配置文件。表单只收集信息 + 做本地校验，**不做任何 IO**。
//
// 校验规则与后端 services/opencode_config.rs 逐条对齐（前端先拦，后端再兜底）：
// - provider key：`^[a-z0-9]+(-[a-z0-9]+)*$`，且不能与既有厂商重名（编辑时可保留自身）；
// - 名称 / Base URL 必填，Base URL 必须 http(s)；
// - 至少一个模型 id。
//
// 「自动派生 + 可编辑」的 key：用户输入名称时自动 slug 化填进 key 框；
// 一旦用户手动改过 key，就不再被名称覆盖（dirty 标记）。

const inputCls =
  "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";
const fieldLabelCls = "mb-0.5 block text-[10px] text-muted-foreground";

/** 与后端 `slugify_provider_key` 同规则（保持两端一致）。 */
export function slugifyProviderKey(name: string): string {
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
export function isValidProviderKey(key: string): boolean {
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(key);
}

/** 新建空白厂商草稿。 */
export function emptyOpenCodeProvider(defaultNpm: string): OpenCodeProviderEntry {
  return {
    id: "",
    name: "",
    npm: defaultNpm,
    baseURL: "",
    apiKey: "",
    models: [{ id: "", name: "" }],
  };
}

export function OpenCodeProviderForm({
  value,
  npmPackages,
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
  value: OpenCodeProviderEntry;
  npmPackages: NpmPackageOption[];
  /** 已存在的厂商 key（查重用；编辑时排除自身）。 */
  existingIds: string[];
  busy: boolean;
  /** true = 编辑既有厂商（key 不可改）。 */
  isEdit: boolean;
  onChange: (next: OpenCodeProviderEntry) => void;
  onCancel: () => void;
  onSave: () => void;
  /** 拉取上游模型清单（可选能力；失败不影响手动填写）。 */
  onFetchModels: () => void;
  fetchingModels: boolean;
  fetchErr: string | null;
}) {
  const { t } = useI18n();
  /** key 是否被用户手动改过（改过则不再随名称自动派生）。 */
  const [keyDirty, setKeyDirty] = useState(isEdit);
  const [advancedOpen, setAdvancedOpen] = useState(false);

  const keyConflict = useMemo(
    () =>
      existingIds.some((id) => id === value.id) && !isEdit,
    [existingIds, value.id, isEdit],
  );

  const keyError = !value.id.trim()
    ? t("oc.errKeyRequired")
    : !isValidProviderKey(value.id.trim())
      ? t("oc.errKeyFormat")
      : keyConflict
        ? t("oc.errKeyTaken")
        : null;

  const modelsValid = value.models.some((m) => m.id.trim());
  const canSave =
    !busy &&
    !keyError &&
    value.name.trim().length > 0 &&
    value.baseURL.trim().length > 0 &&
    modelsValid;

  /** 名称变化：未手动改过 key 时自动派生。 */
  const handleNameChange = (name: string) => {
    if (!keyDirty && !isEdit) {
      onChange({ ...value, name, id: slugifyProviderKey(name) });
    } else {
      onChange({ ...value, name });
    }
  };

  const updateModel = (index: number, patch: Partial<OpenCodeModelEntry>) => {
    const models = value.models.map((m, i) =>
      i === index ? { ...m, ...patch } : m,
    );
    onChange({ ...value, models });
  };
  const addModel = () =>
    onChange({ ...value, models: [...value.models, { id: "", name: "" }] });
  const removeModel = (index: number) =>
    onChange({
      ...value,
      models: value.models.filter((_, i) => i !== index),
    });

  return (
    <div className="flex flex-col gap-2.5 rounded-md border border-border p-2.5">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-foreground">
          {isEdit ? t("oc.editTitle") : t("oc.addTitle")}
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
        {t("oc.formHint")}
      </div>

      {/* 名称 + provider key（自动派生、可编辑） */}
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
          className={cn(
            inputCls,
            "font-mono",
            keyError && "border-destructive/50",
          )}
          placeholder={t("oc.keyPlaceholder")}
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

      {/* npm 接口包（对应 opencode provider.<id>.npm） */}
      <div>
        <span className={fieldLabelCls}>{t("oc.npm")}</span>
        <select
          className={inputCls}
          value={value.npm}
          onChange={(e) => onChange({ ...value, npm: e.target.value })}
        >
          {npmPackages.map((p) => (
            <option key={p.value} value={p.value}>
              {p.label}
            </option>
          ))}
        </select>
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.baseUrl")}</span>
        <input
          className={cn(inputCls, "font-mono")}
          placeholder={t("mp.baseUrlPlaceholder")}
          value={value.baseURL}
          onChange={(e) => onChange({ ...value, baseURL: e.target.value })}
        />
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

      {/* 模型列表（opencode `provider.<id>.models.<modelId>`）*/}
      <div>
        <div className="mb-1 flex items-center justify-between">
          <span className="text-[10px] text-muted-foreground">
            {t("oc.models")}
          </span>
          <div className="flex items-center gap-1">
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
            <Button
              variant="ghost"
              size="sm"
              className="h-6 gap-1 px-2 text-[10px]"
              onClick={addModel}
            >
              <Plus size={10} />
              {t("oc.addModel")}
            </Button>
          </div>
        </div>
        {fetchErr && (
          <p className="mb-1 text-[10px] leading-relaxed text-warning">
            {fetchErr}
          </p>
        )}
        <div className="flex flex-col gap-1.5">
          {value.models.map((m, i) => (
            <div key={i} className="flex items-center gap-1.5">
              <input
                className={cn(inputCls, "font-mono")}
                placeholder={t("oc.modelIdPlaceholder")}
                value={m.id}
                onChange={(e) => updateModel(i, { id: e.target.value })}
              />
              <input
                className={inputCls}
                placeholder={t("oc.modelNamePlaceholder")}
                value={m.name}
                onChange={(e) => updateModel(i, { name: e.target.value })}
              />
              <button
                type="button"
                className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-destructive"
                title={t("mp.delete")}
                disabled={value.models.length <= 1}
                onClick={() => removeModel(i)}
              >
                <X size={11} />
              </button>
            </div>
          ))}
        </div>
        {!modelsValid && (
          <p className="mt-1 text-[10px] text-destructive">
            {t("oc.errModelsRequired")}
          </p>
        )}
      </div>

      {/* 高级：请求头（低频，默认折叠）*/}
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
            {t("oc.headersHint")}
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
