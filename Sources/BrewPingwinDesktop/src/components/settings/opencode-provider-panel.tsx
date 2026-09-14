import { Check, FileCode2, Loader2, Pencil, Plus, Trash2 } from "lucide-react";
import type { OpenCodeProviderEntry, OpenCodeProvidersInfo } from "../../api/types";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

/** base_url 去协议前缀后展示（卡片副标题）。 */
function hostOf(baseUrl: string): string {
  return baseUrl.replace(/^https?:\/\//i, "");
}

/** npm 包名 → 短标签（完整标签在下拉里，卡片上要短）。 */
function npmLabel(npm: string): string {
  return npm.replace(/^@ai-sdk\//, "");
}

/**
 * OpenCode 厂商列表（对标 cc-switch 的「添加厂商」）：
 * 直接来自本机 opencode.json 的 `provider` 段 —— 保存 = 写文件、
 * 删除 = 删文件条目，**没有二次存储**，所以这里看到的就是 opencode 看到的。
 *
 * 与 AgentProviderPanel 的区别：那个管 BrewPing 自己的转发链路（模型配置），
 * 这个管 opencode CLI 自己读的配置文件，两者互不干扰。
 */
export function OpenCodeProviderPanel({
  info,
  loading,
  confirmId,
  onAdd,
  onEdit,
  onDelete,
}: {
  info: OpenCodeProvidersInfo | null;
  loading: boolean;
  /** 两步删除确认：待确认的厂商 key。 */
  confirmId: string | null;
  onAdd: () => void;
  onEdit: (p: OpenCodeProviderEntry) => void;
  onDelete: (id: string) => void;
}) {
  const { t } = useI18n();
  const providers = info?.providers ?? [];

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-1.5">
        <span className="min-w-0 flex-1 truncate text-[10px] text-muted-foreground">
          {t("oc.subtitle")}
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

      {/* 配置文件路径（让用户知道东西写到哪了） */}
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

      {loading ? (
        <div className="flex items-center justify-center py-4 text-muted-foreground">
          <Loader2 size={14} className="animate-spin" />
        </div>
      ) : providers.length === 0 ? (
        <div className="py-3 text-center">
          <div className="text-xs text-muted-foreground">{t("oc.empty")}</div>
          <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
            {t("oc.emptyHint")}
          </div>
        </div>
      ) : (
        providers.map((p) => (
          <div
            key={p.id}
            className="rounded-md border border-border px-2.5 py-1.5 transition-colors hover:bg-accent/50"
          >
            <div className="flex items-center gap-1.5">
              <Check size={13} className="shrink-0 text-primary" />
              <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
                {p.name}
              </span>
              <Badge
                variant="secondary"
                className="shrink-0 px-1.5 py-0 font-mono text-[9px]"
              >
                {p.id}
              </Badge>
              <div className="flex shrink-0 items-center gap-0.5">
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
                {npmLabel(p.npm)}
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
              <span className="shrink-0 text-[9px] text-muted-foreground/70">
                {t("oc.modelCount", { n: p.models.length })}
              </span>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
