import {
  Check,
  FileCode2,
  FileJson2,
  Loader2,
  Pencil,
  Plus,
  Trash2,
  Zap,
} from "lucide-react";
import type { PiProviderEntry, PiProvidersInfo } from "../../api/types";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

/** baseUrl 去协议前缀后展示（卡片副标题）。 */
function hostOf(baseUrl: string): string {
  return baseUrl.replace(/^https?:\/\//i, "");
}

/**
 * pi 厂商列表（对标 cc-switch 的「添加厂商」）：
 * 直接来自本机 `~/.pi/agent/models.json` 的 `providers.*` ——
 * 保存 = 写节点、删除 = 摘节点，**没有二次存储**。
 *
 * 与 CliTakeover 的区别：那个把 baseUrl 指向本地转发代理（固定值），
 * 这个写用户自定义厂商（真地址真 Key）。
 *
 * 默认项（`defaultProvider` / `defaultModel`）写在同目录的 `settings.json`，
 * 卡片上的「设为默认」按钮就是改这两个键（成对写，避免 defaultModel 悬空）。
 */
export function PiProviderPanel({
  info,
  loading,
  confirmId,
  busyId,
  onAdd,
  onEdit,
  onDelete,
  onActivate,
}: {
  info: PiProvidersInfo | null;
  loading: boolean;
  /** 两步删除确认：待确认的厂商 key。 */
  confirmId: string | null;
  /** 正在切换默认项 / 删除中的 key（禁用按钮防重复点击）。 */
  busyId: string | null;
  onAdd: () => void;
  onEdit: (p: PiProviderEntry) => void;
  onDelete: (id: string) => void;
  onActivate: (id: string) => void;
}) {
  const { t } = useI18n();
  const providers = info?.providers ?? [];

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-1.5">
        <span className="min-w-0 flex-1 truncate text-[10px] text-muted-foreground">
          {t("pi.subtitle")}
        </span>
        <Button
          variant="outline"
          size="sm"
          className="h-6 shrink-0 gap-1 px-2 text-[10px]"
          onClick={onAdd}
        >
          <Plus size={11} />
          {t("oc.add")}
        </Button>
      </div>

      {/* 两个落点都展示：models.json 存厂商、settings.json 存默认项 */}
      <div className="flex flex-col gap-0.5">
        {info?.configFile && (
          <div
            className="flex items-center gap-1 truncate font-mono text-[10px] text-muted-foreground/70"
            title={info.configFile}
          >
            <FileCode2 size={10} className="shrink-0" />
            <span className="truncate">{info.configFile}</span>
            {!info.exists && (
              <Badge variant="secondary" className="shrink-0 px-1.5 py-0 text-[9px]">
                {t("oc.notCreated")}
              </Badge>
            )}
          </div>
        )}
        {info?.settingsFile && (
          <div
            className="flex items-center gap-1 truncate font-mono text-[10px] text-muted-foreground/70"
            title={info.settingsFile}
          >
            <FileJson2 size={10} className="shrink-0" />
            <span className="truncate">{info.settingsFile}</span>
          </div>
        )}
      </div>

      {info?.defaultProvider && (
        <div className="flex items-center gap-1.5 rounded-md bg-muted/60 px-2 py-1">
          <span className="shrink-0 text-[10px] text-muted-foreground">
            {t("pi.defaultLabel")}
          </span>
          <span className="min-w-0 flex-1 truncate font-mono text-[10px] text-foreground">
            {info.defaultProvider}
            {info.defaultModel ? ` / ${info.defaultModel}` : ""}
          </span>
        </div>
      )}

      {loading ? (
        <div className="flex items-center justify-center py-4 text-muted-foreground">
          <Loader2 size={14} className="animate-spin" />
        </div>
      ) : providers.length === 0 ? (
        <div className="py-3 text-center">
          <div className="text-xs text-muted-foreground">{t("oc.empty")}</div>
          <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
            {t("pi.emptyHint")}
          </div>
        </div>
      ) : (
        providers.map((p) => (
          <div
            key={p.id}
            className={cn(
              "rounded-md border px-2.5 py-1.5 transition-colors",
              p.isDefault
                ? "border-primary/40 bg-primary/[0.04]"
                : "border-border hover:bg-accent/50",
            )}
          >
            <div className="flex items-center gap-1.5">
              {p.isDefault ? (
                <Check size={13} className="shrink-0 text-primary" />
              ) : (
                <span className="w-[13px] shrink-0" />
              )}
              <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
                {p.name || p.id}
              </span>
              {p.isDefault && (
                <Badge
                  variant="success"
                  className="shrink-0 px-1.5 py-0 text-[9px]"
                >
                  {t("pi.default")}
                </Badge>
              )}
              <Badge
                variant="secondary"
                className="shrink-0 px-1.5 py-0 font-mono text-[9px]"
              >
                {p.id}
              </Badge>
              <div className="flex shrink-0 items-center gap-0.5">
                {!p.isDefault && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-6 w-6 p-0"
                    title={t("pi.setDefault")}
                    disabled={busyId === p.id}
                    onClick={() => onActivate(p.id)}
                  >
                    {busyId === p.id ? (
                      <Loader2 size={11} className="animate-spin" />
                    ) : (
                      <Zap size={11} />
                    )}
                  </Button>
                )}
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-6 w-6 p-0"
                  title={t("mp.edit")}
                  onClick={() => onEdit(p)}
                >
                  <Pencil size={11} />
                </Button>
                <Button
                  variant={confirmId === p.id ? "destructive" : "ghost"}
                  size="sm"
                  className={cn(
                    "h-6 p-0",
                    confirmId === p.id ? "w-auto px-2 text-[10px]" : "w-6",
                  )}
                  title={t("mp.delete")}
                  onClick={() => onDelete(p.id)}
                >
                  <Trash2 size={11} />
                  {confirmId === p.id && t("mp.confirmDelete")}
                </Button>
              </div>
            </div>
            <div className="mt-0.5 flex items-center gap-1.5">
              <span
                className="min-w-0 flex-1 truncate font-mono text-[10px] text-muted-foreground"
                title={p.baseURL}
              >
                {p.baseURL ? hostOf(p.baseURL) : "—"}
              </span>
              <Badge variant="secondary" className="shrink-0 px-1.5 py-0 text-[9px]">
                {p.api}
              </Badge>
              <Badge
                variant={p.apiKey ? "success" : "secondary"}
                className={cn(
                  "shrink-0 px-1.5 py-0 text-[9px]",
                  !p.apiKey && "opacity-70",
                )}
              >
                {p.apiKey ? t("mp.keySet") : t("mp.keyMissing")}
              </Badge>
              <span
                className="shrink-0 font-mono text-[9px] text-muted-foreground/70"
                title={p.models.map((m) => m.id).join(", ")}
              >
                {t("pi.modelCount", { count: p.models.length })}
              </span>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
