import { useEffect, useRef, useState } from "react";
import {
  ArrowUp,
  Check,
  ChevronDown,
  Folder,
  FolderOpen,
  HardDrive,
  Home,
  X,
} from "lucide-react";
import {
  browseFolder,
  browseRoots,
} from "../../api/tauri";
import type { BrowseRootsInfo, BrowseResultInfo } from "../../api/types";
import { cn } from "../../lib/utils";

// ─── 工作目录条（composer 上方；视觉对齐参考截图的 📁 workFlow 圆角边框条）────
// 触发条 = Folder 图标 + 目录路径（末段加粗）+ 右侧作用范围提示；
// 点击向上展开圆角卡片弹层：快捷位置 + 目录浏览器（进入 / 返回 / 选中），
// 选中即刻生效并持久化（后续对话与文件操作作用于所选目录）。

const BAR_CLASS =
  "mb-2 flex h-9 w-full items-center gap-2 rounded-xl border border-input-border " +
  "bg-background px-3 text-xs text-muted-foreground transition-colors " +
  "cursor-pointer hover:border-primary/40 hover:text-foreground";

const POPUP_CLASS =
  "absolute bottom-full left-0 right-0 z-[var(--z-popover)] mb-2 " +
  "rounded-xl border border-border bg-popover text-popover-foreground p-1.5 " +
  "shadow-[0_8px_28px_rgba(63,46,30,0.14),0_2px_8px_rgba(63,46,30,0.08)] " +
  "composer-popup-in";

const ROW_CLASS =
  "flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left " +
  "transition-colors cursor-pointer hover:bg-accent";

/** 路径末段作为主标题（`D:\study\workFlow` → `workFlow`）。 */
function pathLabel(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const idx = Math.max(trimmed.lastIndexOf("\\"), trimmed.lastIndexOf("/"));
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

export function WorkdirPicker({
  workdir,
  recentDirs = [],
  hint = "对话与文件操作将作用于所选目录",
  onChange,
}: {
  /** 当前生效目录（null = 未绑定，回落 CLI 默认 / agent 偏好）。 */
  workdir: string | null;
  /** 最近使用的目录（来自历史对话的绑定，按最近活动排序）。 */
  recentDirs?: string[];
  /** 触发条右侧的作用范围提示（草稿态 / 已绑定可分别措辞）。 */
  hint?: string;
  /** 选择 / 清除后回调（持久化由 App 层决定：写入对话绑定或草稿态）。 */
  onChange: (path: string | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [roots, setRoots] = useState<BrowseRootsInfo | null>(null);
  const [browse, setBrowse] = useState<BrowseResultInfo | null>(null);
  const [browseError, setBrowseError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [manualPath, setManualPath] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);

  // 点外面 / Esc 关闭
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // 首次展开：拉根列表；浏览起点 = 已选目录 ?? 主目录
  useEffect(() => {
    if (!open) return;
    let alive = true;
    void (async () => {
      try {
        const r = await browseRoots();
        if (!alive) return;
        setRoots(r);
        if (!browse) {
          await enter(workdir ?? r.homeDir ?? null);
        }
      } catch {
        /* 根列表失败时浏览器区显示错误 */
      }
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const enter = async (path: string | null) => {
    setBusy(true);
    setBrowseError(null);
    try {
      const r = await browseFolder(path);
      setBrowse(r);
    } catch (e) {
      setBrowseError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const pick = (path: string | null) => {
    onChange(path);
    setOpen(false);
  };

  const dirs = (browse?.entries ?? []).filter((e) => !e.hidden);

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        className={BAR_CLASS}
        onClick={() => setOpen((v) => !v)}
        title={workdir ?? "未设置工作目录（使用 CLI 默认位置）"}
      >
        <Folder size={14} className="shrink-0 text-primary/80" />
        {workdir ? (
          <span className="min-w-0 truncate whitespace-nowrap">
            <span className="font-medium text-foreground">{pathLabel(workdir)}</span>
            <span className="ml-1.5 hidden text-muted-foreground sm:inline">
              {workdir}
            </span>
          </span>
        ) : (
          <span className="min-w-0 truncate whitespace-nowrap">
            未设置工作目录
            <span className="ml-1.5 text-muted-foreground/70">
              （将使用 CLI 默认位置）
            </span>
          </span>
        )}
        <span className="ml-auto hidden shrink-0 text-[10px] text-muted-foreground/70 md:inline">
          {hint}
        </span>
        <ChevronDown
          size={12}
          className={cn("shrink-0 opacity-60 transition-transform", open && "rotate-180")}
        />
      </button>

      {open && (
        <div className={POPUP_CLASS}>
          {/* 当前生效目录 + 清除 */}
          <div className="flex items-center gap-2 px-2.5 py-1.5">
            <span className="min-w-0 flex-1 truncate text-[10px] text-muted-foreground">
              当前：{workdir ?? "未设置（CLI 默认位置）"}
            </span>
            {workdir && (
              <button
                type="button"
                className="flex h-5 shrink-0 items-center gap-1 rounded-md px-1.5 text-[10px] text-muted-foreground hover:bg-accent hover:text-foreground"
                onClick={() => void pick(null)}
                title="清除偏好，恢复 CLI 默认位置"
              >
                <X size={11} />
                清除
              </button>
            )}
          </div>

          <div className="my-1 border-t border-border" />

          {/* 快捷位置：主目录 + 盘符 */}
          <div className="flex flex-wrap gap-1 px-1.5 pb-1">
            {roots?.homeDir && (
              <button
                type="button"
                className={cn(ROW_CLASS, "h-7 w-auto px-2 py-0 text-xs")}
                onClick={() => void enter(roots.homeDir)}
                title={roots.homeDir}
              >
                <Home size={12} className="shrink-0" />
                主目录
              </button>
            )}
            {(roots?.drives ?? []).map((d) => (
              <button
                key={d}
                type="button"
                className={cn(ROW_CLASS, "h-7 w-auto px-2 py-0 text-xs")}
                onClick={() => void enter(d)}
                title={d}
              >
                <HardDrive size={12} className="shrink-0" />
                {d.replace("\\", "")}
              </button>
            ))}
          </div>

          <div className="my-1 border-t border-border" />

          {/* 最近使用（来自历史对话的绑定目录） */}
          {recentDirs.length > 0 && (
            <>
              <div className="px-2.5 pb-1 pt-0.5 text-[10px] text-muted-foreground/70">
                最近使用
              </div>
              <div className="flex flex-wrap gap-1 px-1.5 pb-1">
                {recentDirs.slice(0, 6).map((d) => (
                  <button
                    key={d}
                    type="button"
                    className={cn(
                      ROW_CLASS,
                      "h-7 w-auto max-w-56 px-2 py-0 text-xs",
                      workdir === d && "bg-accent font-medium text-foreground",
                    )}
                    onClick={() => pick(d)}
                    title={d}
                  >
                    <FolderOpen size={12} className="shrink-0 text-primary/70" />
                    <span className="min-w-0 truncate">{pathLabel(d)}</span>
                  </button>
                ))}
              </div>
              <div className="my-1 border-t border-border" />
            </>
          )}

          {/* 手动输入路径（回车或 ✓ 确认；目录不存在时后端拒绝） */}
          <div className="flex items-center gap-1.5 px-1.5 pb-1">
            <input
              className="h-7 min-w-0 flex-1 rounded-lg border border-input-border bg-background px-2 text-xs text-foreground placeholder:text-muted-foreground/50 focus-visible:border-primary/50 focus-visible:outline-none"
              placeholder="或直接输入目录路径，如 D:\work\project"
              value={manualPath}
              onChange={(e) => setManualPath(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && manualPath.trim()) {
                  pick(manualPath.trim());
                  setManualPath("");
                }
              }}
            />
            <button
              type="button"
              className="flex h-7 shrink-0 items-center rounded-lg px-2 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
              disabled={!manualPath.trim()}
              onClick={() => {
                pick(manualPath.trim());
                setManualPath("");
              }}
              title="绑定输入的目录"
            >
              <Check size={13} />
            </button>
          </div>

          {/* 浏览器：返回上级 + 当前浏览路径 */}
          <div className="flex items-center gap-1.5 px-2.5 py-1">
            <button
              type="button"
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
              disabled={!browse?.parentPath || busy}
              onClick={() => void enter(browse?.parentPath ?? null)}
              title="上一级"
            >
              <ArrowUp size={12} />
            </button>
            <span className="min-w-0 flex-1 truncate text-[10px] text-muted-foreground">
              {browse?.path ?? "…"}
            </span>
          </div>

          {/* 子目录列表：点名字进入；点右侧选中此目录 */}
          <div className="max-h-56 overflow-y-auto">
            {browseError && (
              <div className="break-all px-2.5 py-2 text-[10px] leading-relaxed text-warning">
                {browseError}
              </div>
            )}
            {!browseError && dirs.length === 0 && (
              <div className="px-2.5 py-2 text-[10px] text-muted-foreground">
                {busy ? "加载中…" : "没有子目录"}
              </div>
            )}
            {dirs.map((e) => {
              const selected = workdir === e.absolutePath;
              return (
                <div key={e.absolutePath} className={cn(ROW_CLASS, "pr-1.5")}>
                  <button
                    type="button"
                    className="flex min-w-0 flex-1 items-center gap-2 text-left"
                    onClick={() => void enter(e.absolutePath)}
                    title={e.absolutePath}
                  >
                    <FolderOpen size={13} className="shrink-0 text-primary/70" />
                    <span className="min-w-0 truncate text-xs text-foreground">
                      {e.name}
                    </span>
                  </button>
                  <button
                    type="button"
                    className={cn(
                      "flex h-6 w-6 shrink-0 items-center justify-center rounded-md transition-colors",
                      selected
                        ? "text-primary"
                        : "text-muted-foreground/50 hover:bg-accent hover:text-foreground",
                    )}
                    onClick={() => void pick(e.absolutePath)}
                    title={`选定 ${e.absolutePath} 为工作目录`}
                  >
                    <Check size={13} />
                  </button>
                </div>
              );
            })}
          </div>

          <div className="my-1 border-t border-border" />

          <div className="px-2.5 py-1.5 text-[10px] leading-relaxed text-muted-foreground/70">
            点目录名进入，点右侧 ✓ 选定。后续对话与文件操作将作用于所选目录。
          </div>
        </div>
      )}
    </div>
  );
}
