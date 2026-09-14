import { AlertTriangle, Check, Pencil, Plus, Trash2 } from "lucide-react";
import type { CliTakeoverItem, ModelProviderConfig } from "../../api/types";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

/** base_url 去协议前缀后展示（卡片副标题）。 */
function hostOf(baseUrl: string): string {
  return baseUrl.replace(/^https?:\/\//i, "");
}

/**
 * 未接管黄条（独立组件）。
 *
 * 语义：本 tab 对应的 CLI 已安装、支持接管，但配置**尚未**指向本地转发代理
 * → 用户在这里配的厂商不会生效 → 给出「一键接入」救命按钮。
 *
 * 刻意从 `AgentProviderPanel` 里抽出来：整个「转发代理厂商列表」区块已被
 * `model-config-card.tsx` 的 `SHOW_FORWARD_PROXY_SECTION` 特性开关屏蔽，
 * 但**这条黄条必须保留**（它是用户唯一能感知"配置为什么不生效"的入口，
 * 也是恢复接管的唯一按钮）。因此它不受该开关影响，单独渲染。
 *
 * 不显示的条件（任一命中即不渲染）：
 * - 该 tab 没有对应的 CLI（`takeoverItem == null`，如「通用」tab）；
 * - 该 CLI 不支持接管（`supported === false`，如 OpenCode）—— 否则按钮点下去会报错；
 * - 已经指向代理（`active === true`）。
 */
export function TakeoverNotice({
  takeoverItem,
  busy,
  onConnectCli,
}: {
  takeoverItem: CliTakeoverItem | null;
  busy: boolean;
  onConnectCli: () => void;
}) {
  const { t } = useI18n();
  if (!takeoverItem || !takeoverItem.supported || takeoverItem.active) {
    return null;
  }
  return (
    <div className="flex items-center gap-2 rounded-md border border-warning/40 bg-warning/10 px-2.5 py-1.5">
      <AlertTriangle size={12} className="shrink-0 text-warning" />
      <span className="min-w-0 flex-1 text-[10px] leading-relaxed text-warning">
        {t("mp.notTakenOver", { name: takeoverItem.name })}
      </span>
      <Button
        variant="outline"
        size="sm"
        className="h-6 shrink-0 px-2 text-[10px]"
        disabled={busy}
        onClick={onConnectCli}
      >
        {t("mp.connectNow")}
      </Button>
    </div>
  );
}

/**
 * 单个 Agent 归属下的厂商面板（P2）：
 * - 列表 = 该 Agent 专属厂商 + 通用厂商（带「通用」徽章，仅可设为当前）；
 * - 当前判定用调用方解析好的 per-Agent 生效值（currentByAgent → currentId 回落）；
 * - 未接管黄条（TakeoverNotice）仅在 `showTakeover` 为 true 时渲染
 *   （由 `model-config-card.tsx` 的 `SHOW_TAKEOVER_UI` 开关统一控制）。
 */
export function AgentProviderPanel({
  agentId,
  providers,
  currentId,
  busy,
  confirmId,
  takeoverItem,
  showTakeover = false,
  onSetCurrent,
  onEdit,
  onDelete,
  onConnectCli,
  onAdd,
}: {
  /** 当前 tab 归属（"" = 通用 tab）。 */
  agentId: string;
  providers: ModelProviderConfig[];
  currentId: string | null;
  busy: boolean;
  confirmId: string | null;
  /** tab 身份对应的 CLI 接入项（claude-code→claude_code 等；无对应 = null）。 */
  takeoverItem: CliTakeoverItem | null;
  /** 是否渲染未接管黄条（🚧 接管 UI 暂时全量隐藏，默认 false）。 */
  showTakeover?: boolean;
  onSetCurrent: (id: string) => void;
  onEdit: (p: ModelProviderConfig) => void;
  onDelete: (id: string) => void;
  onConnectCli: () => void;
  onAdd: () => void;
}) {
  const { t } = useI18n();
  const isGenericTab = agentId === "";

  return (
    <div className="flex flex-col gap-1.5">
      {/* 未接管黄条：配置好了但 CLI 没指向代理 → 配置不生效 */}
      {showTakeover && (
        <TakeoverNotice
          takeoverItem={takeoverItem}
          busy={busy}
          onConnectCli={onConnectCli}
        />
      )}

      {providers.length === 0 ? (
        <div className="py-3 text-center">
          <div className="text-xs text-muted-foreground">
            {t("mp.tabEmpty")}
          </div>
          <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
            {t("mp.tabEmptyHint")}
          </div>
          <Button
            variant="outline"
            size="sm"
            className="mt-2 h-6 gap-1 px-2 text-[10px]"
            disabled={busy}
            onClick={onAdd}
          >
            <Plus size={11} />
            {t("mp.add")}
          </Button>
        </div>
      ) : (
        providers.map((p) => {
          const isCurrent = currentId === p.id;
          // 通用厂商在专属 tab 下仅可「设为当前」；编辑/删除回通用 tab 操作
          const isSharedHere = !isGenericTab && p.agentId === "";
          const canManage = !isSharedHere;
          return (
            <div
              key={p.id}
              className={cn(
                "rounded-md border px-2.5 py-1.5 transition-colors",
                isCurrent
                  ? "border-primary/30 bg-primary/5"
                  : "border-border hover:bg-accent/50",
              )}
            >
              {/* 行 1：名称 + 当前/通用徽章 + 操作 */}
              <div className="flex items-center gap-1.5">
                {isCurrent && (
                  <Check size={13} className="shrink-0 text-primary" />
                )}
                <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
                  {p.name}
                </span>
                {isCurrent && (
                  <Badge
                    variant="success"
                    className="shrink-0 px-1.5 py-0 text-[9px]"
                  >
                    {t("mp.current")}
                  </Badge>
                )}
                {isSharedHere && (
                  <Badge
                    variant="secondary"
                    className="shrink-0 px-1.5 py-0 text-[9px]"
                  >
                    {t("mp.genericBadge")}
                  </Badge>
                )}
                <div className="flex shrink-0 items-center gap-0.5">
                  {!isCurrent && (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-6 px-2 text-[10px]"
                      disabled={busy}
                      onClick={() => onSetCurrent(p.id)}
                    >
                      {t("mp.setCurrent")}
                    </Button>
                  )}
                  {canManage && (
                    <>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-6 w-6 p-0"
                        disabled={busy}
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
                          confirmId === p.id
                            ? "w-auto px-2 text-[10px]"
                            : "w-6",
                        )}
                        disabled={busy}
                        title={t("mp.delete")}
                        onClick={() => onDelete(p.id)}
                      >
                        <Trash2 size={11} />
                        {confirmId === p.id && t("mp.confirmDelete")}
                      </Button>
                    </>
                  )}
                </div>
              </div>
              {/* 行 2：base_url + 协议 + Key 状态 + 映射模型（4 信息位） */}
              <div className="mt-0.5 flex items-center gap-1.5">
                <span
                  className="min-w-0 flex-1 truncate font-mono text-[10px] text-muted-foreground"
                  title={p.baseUrl}
                >
                  {hostOf(p.baseUrl)}
                </span>
                <Badge
                  variant="secondary"
                  className="shrink-0 px-1.5 py-0 text-[9px]"
                >
                  {t(`mp.format.${p.apiFormat}`)}
                </Badge>
                <Badge
                  variant={p.hasKey ? "success" : "secondary"}
                  className={cn(
                    "shrink-0 px-1.5 py-0 text-[9px]",
                    !p.hasKey && "opacity-70",
                  )}
                >
                  {p.hasKey ? t("mp.keySet") : t("mp.keyMissing")}
                </Badge>
                {p.model && (
                  <span className="shrink-0 truncate font-mono text-[9px] text-muted-foreground/70">
                    {p.model}
                  </span>
                )}
              </div>
            </div>
          );
        })
      )}
    </div>
  );
}
