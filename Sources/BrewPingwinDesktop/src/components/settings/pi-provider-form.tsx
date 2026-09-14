import { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Loader2, Plus, Trash2, X } from "lucide-react";
import type {
  CatalogEndpoint,
  CatalogEntry,
  PiApiOption,
  PiModelEntry,
  PiProviderEntry,
} from "../../api/types";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";
import { VendorPresetSelect } from "./vendor-preset-select";

// ─── pi「添加 / 编辑厂商」表单（对标 cc-switch）─────────────────────────────
//
// 保存后由后端写进 ~/.pi/agent/models.json 的 providers.<key>（增量模式：
// 只动这一个节点，其余原样保留），**不碰 auth.json**（pi 自己的 /login 凭据）。
// 表单只收集信息 + 做本地校验，**不做任何 IO**。
//
// 校验规则与后端 services/pi_config.rs 逐条对齐：
// - provider key：`^[a-z0-9]+(-[a-z0-9]+)*$`，**编辑时不可改名**（后端拒绝改名，
//   因为改 key = 删旧建新，会让 settings.json 里的 defaultProvider 悬空）；
// - baseUrl 必填且 http(s)；api 三选一；models 至少一条。
//
// 注意大小写：pi 的字段名是 `baseUrl`（不是 `baseURL`），但 DTO 统一用 baseURL
// 以对齐其它两个 agent，由后端负责映射。

const inputCls =
  "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";
const fieldLabelCls = "mb-0.5 block text-[10px] text-muted-foreground";

/** 与后端 `slugify_provider_key` 同规则。 */
export function slugifyPiKey(name: string): string {
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
export function isValidPiKey(key: string): boolean {
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(key);
}

/** 新建空白厂商草稿（默认带一条空模型，避免用户面对空清单无从下手）。 */
export function emptyPiProvider(defaultApi: string): PiProviderEntry {
  return {
    id: "",
    name: "",
    baseURL: "",
    apiKey: "",
    api: defaultApi || "anthropic-messages",
    models: [{ id: "", name: "" }],
    isDefault: false,
  };
}

/**
 * 编辑既有厂商前归一化（兜底运行时缺失字段）。
 *
 * 🚨 `entry` 来自 Tauri IPC（运行时边界），TS 类型不保证字段真的存在。
 * 曾因后端把 `base_url` 序列化成 camelCase 派生的 `baseUrl`（而非约定的
 * `baseURL`），导致 `value.baseURL` 是 undefined，表单里 `value.baseURL.trim()`
 * 抛 TypeError → 整棵树卸载 = 白屏。在此处统一补空串，比逐点防御可靠。
 *
 * `models` 至少留一条空行（编辑态不能出现空清单，否则无法新增）。
 */
export function normalizePiEntry(entry: PiProviderEntry): PiProviderEntry {
  const models = entry.models ?? [];
  return {
    ...entry,
    id: entry.id ?? "",
    name: entry.name ?? "",
    baseURL: entry.baseURL ?? "",
    apiKey: entry.apiKey ?? "",
    api: entry.api ?? "anthropic-messages",
    models: models.length ? models.map((m) => ({ ...m })) : [{ id: "", name: "" }],
    isDefault: entry.isDefault ?? false,
  };
}

export function PiProviderForm({
  value,
  apis,
  catalog,
  existingIds,
  busy,
  isEdit,
  error,
  onChange,
  onCancel,
  onSave,
}: {
  value: PiProviderEntry;
  apis: PiApiOption[];
  /** 厂商目录（预填模板；空数组则不显示下拉）。 */
  catalog: CatalogEntry[];
  /** 已存在的厂商 key（查重用；编辑时排除自身）。 */
  existingIds: string[];
  busy: boolean;
  /** true = 编辑既有厂商（key 不可改）。 */
  isEdit: boolean;
  error: string | null;
  onChange: (next: PiProviderEntry) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  const { t } = useI18n();
  const [keyDirty, setKeyDirty] = useState(isEdit);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  /** 当前选中的目录 id（仅用于下拉回显）。 */
  const [presetId, setPresetId] = useState("");

  const keyConflict = useMemo(
    () => existingIds.some((id) => id === value.id) && !isEdit,
    [existingIds, value.id, isEdit],
  );

  const keyError = !value.id.trim()
    ? t("oc.errKeyRequired")
    : !isValidPiKey(value.id.trim())
      ? t("oc.errKeyFormat")
      : keyConflict
        ? t("oc.errKeyTaken")
        : null;

  const baseError = useMemo(() => {
    const base = value.baseURL.trim();
    if (!base) return t("oc.errBaseRequired");
    if (!/^https?:\/\//i.test(base)) return t("oc.errBaseScheme");
    return null;
  }, [value.baseURL, t]);

  /** 至少一条非空模型（pi 的 models[] 空数组等于厂商没用）。 */
  const modelError = useMemo(
    () => (value.models.some((m) => m.id.trim()) ? null : t("pi.errModelsRequired")),
    [value.models, t],
  );

  const canSave = !busy && !keyError && !baseError && !modelError;

  const handleNameChange = (name: string) => {
    if (!keyDirty && !isEdit) {
      onChange({ ...value, name, id: slugifyPiKey(name) });
    } else {
      onChange({ ...value, name });
    }
  };

  const setModel = (idx: number, patch: Partial<PiModelEntry>) => {
    onChange({
      ...value,
      models: value.models.map((m, i) => (i === idx ? { ...m, ...patch } : m)),
    });
  };

  const addModel = () => {
    onChange({ ...value, models: [...value.models, { id: "", name: "" }] });
  };

  const removeModel = (idx: number) => {
    onChange({ ...value, models: value.models.filter((_, i) => i !== idx) });
  };

  /**
   * 选了预设厂商 → 预填名称 / key / baseURL / api / 首条模型。
   *
   * 🚨 baseURL 与 api 都来自**按 agent 分派的端点数据**（ep = pi 条目）：
   * pi 走 OpenAI 兼容 Chat 端点（/anthropic 只属于 Claude Code），api 跟随
   * 预设固定为 "openai-completions"（cc-switch 五家同款；api 恒有默认值
   * 无法区分「没填过」，选预设 = 明确要推荐配置，故无条件覆盖 —— 旧注释
   * 「刻意不碰 api」的前提已由 per-agent 端点数据消除）。
   */
  const applyPreset = (c: CatalogEntry, ep: CatalogEndpoint) => {
    setPresetId(c.id);
    const nextName = c.displayName || c.name;
    const presetModel = c.models[0] ?? "";
    const models = value.models.map((m) => ({ ...m }));
    if (presetModel && !models.some((m) => m.id.trim())) {
      if (models.length === 0) models.push({ id: presetModel, name: "" });
      else models[0] = { ...models[0], id: presetModel };
    }
    onChange({
      ...value,
      name: value.name.trim() ? value.name : nextName,
      id: !keyDirty && !isEdit ? slugifyPiKey(nextName) : value.id,
      baseURL: value.baseURL.trim() ? value.baseURL : ep.baseUrl,
      api: ep.piApi || value.api,
      models,
    });
  };

  return (
    <div className="flex flex-col gap-2.5 rounded-md border border-border p-2.5">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-foreground">
          {isEdit ? t("pi.editTitle") : t("pi.addTitle")}
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
        {t("pi.formHint")}
      </div>

      {/* 预设厂商：选一家自动预填名称 / key / baseURL / 首条模型 */}
      <VendorPresetSelect
        catalog={catalog}
        agentId="pi"
        value={presetId}
        disabled={busy}
        onPick={applyPreset}
      />

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
          placeholder={t("pi.keyPlaceholder")}
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
          {isEdit ? t("pi.keyLockedHint") : (keyError ?? t("oc.keyHint"))}
        </p>
      </div>

      <div>
        <span className={fieldLabelCls}>{t("mp.baseUrl")}</span>
        <input
          className={cn(inputCls, "font-mono", baseError && "border-destructive/50")}
          placeholder={t("pi.baseUrlPlaceholder")}
          value={value.baseURL}
          onChange={(e) => onChange({ ...value, baseURL: e.target.value })}
        />
        {baseError && (
          <p className="mt-0.5 text-[10px] text-destructive">{baseError}</p>
        )}
      </div>

      <div>
        <span className={fieldLabelCls}>{t("pi.api")}</span>
        <select
          className={inputCls}
          value={value.api}
          onChange={(e) => onChange({ ...value, api: e.target.value })}
        >
          {apis.map((a) => (
            <option key={a.value} value={a.value}>
              {a.label}
            </option>
          ))}
        </select>
        <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("pi.apiHint")}
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
          {t("pi.apiKeyHint")}
        </p>
      </div>

      {/* 模型清单（providers.<key>.models[]）：增删改，第一条即"设为默认"时用的那条 */}
      <div>
        <div className="mb-1 flex items-center justify-between">
          <span className="text-[10px] text-muted-foreground">
            {t("pi.models")}
          </span>
          <Button
            variant="outline"
            size="sm"
            className="h-6 gap-1 px-2 text-[10px]"
            onClick={addModel}
          >
            <Plus size={10} />
            {t("oc.addModel")}
          </Button>
        </div>
        <div className="flex flex-col gap-1.5">
          {value.models.map((m, idx) => (
            <div key={idx} className="flex items-center gap-1.5">
              <input
                className={cn(inputCls, "font-mono")}
                placeholder={t("pi.modelIdPlaceholder")}
                value={m.id}
                onChange={(e) => setModel(idx, { id: e.target.value })}
              />
              <input
                className={inputCls}
                placeholder={t("oc.modelNamePlaceholder")}
                value={m.name}
                onChange={(e) => setModel(idx, { name: e.target.value })}
              />
              <button
                type="button"
                className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                onClick={() => removeModel(idx)}
                title={t("mp.delete")}
              >
                <Trash2 size={11} />
              </button>
            </div>
          ))}
        </div>
        {modelError && (
          <p className="mt-0.5 text-[10px] text-destructive">{modelError}</p>
        )}
        <p className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
          {t("pi.modelsHint")}
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
            {t("pi.advancedHint")}
          </p>
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
