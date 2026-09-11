import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { Check, ChevronDown } from "lucide-react";
import { cn } from "../../lib/utils";

// ─── Composer 工具栏下拉（圆角卡片弹层，替代原生 select） ─────────────────────
// 视觉参照 Claude 风格：触发器 = 图标 + 单行截断文案 + chevron（同行垂直居中）；
// 弹层 = 从工具栏向上展开的圆角卡片（柔和边框 + 轻阴影），条目两行排版
// （主文案 + 次要描述），hover 浅棕面、选中项右侧对勾。
// 仅样式层替换：onChange 语义与原 <select> 完全一致。

export interface ComposerDropdownOption {
  value: string;
  /** 触发器与条目主文案（单行截断）。 */
  label: string;
  /** 条目第二行次要描述（如模型的 provider），可省略。 */
  description?: string | null;
}

const TRIGGER_CLASS =
  "flex h-7 min-w-0 items-center gap-1.5 rounded-lg px-2 text-xs " +
  "text-muted-foreground transition-colors cursor-pointer " +
  "hover:bg-accent hover:text-foreground";

const POPUP_CLASS =
  "absolute bottom-full z-[var(--z-popover)] mb-2 w-max min-w-44 max-w-80 " +
  "rounded-xl border border-border bg-popover text-popover-foreground p-1.5 " +
  "shadow-[0_8px_28px_rgba(63,46,30,0.14),0_2px_8px_rgba(63,46,30,0.08)] " +
  "composer-popup-in";

const ITEM_CLASS =
  "flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left " +
  "transition-colors cursor-pointer hover:bg-accent";

export function ComposerDropdown({
  icon,
  value,
  options,
  onChange,
  title,
  triggerClassName,
  popupAlign = "left",
}: {
  /** 触发器左侧图标（已含 shrink-0）。 */
  icon: ReactNode;
  value: string;
  options: ComposerDropdownOption[];
  onChange: (value: string) => void;
  /** 悬停提示，透传原 title。 */
  title?: string;
  /** 触发器文案的宽度上限（max-w-*），控制整行不拥挤。 */
  triggerClassName?: string;
  popupAlign?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  // 点外面 / Esc 关闭（不改交互语义：仍是「点开 → 选一项」）
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

  const current = options.find((o) => o.value === value);

  return (
    <div ref={rootRef} className="relative min-w-0">
      <button
        type="button"
        title={title}
        onClick={() => setOpen((v) => !v)}
        className={cn(TRIGGER_CLASS, open && "bg-accent text-foreground", triggerClassName)}
      >
        {icon}
        <span className="min-w-0 truncate whitespace-nowrap">
          {current?.label ?? ""}
        </span>
        <ChevronDown
          size={12}
          className={cn("shrink-0 opacity-60 transition-transform", open && "rotate-180")}
        />
      </button>

      {open && (
        <div className={cn(POPUP_CLASS, popupAlign === "right" ? "right-0" : "left-0")}>
          {options.map((o) => {
            const selected = o.value === value;
            return (
              <button
                key={o.value}
                type="button"
                title={o.description ? `${o.label} · ${o.description}` : o.label}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                }}
                className={cn(ITEM_CLASS, selected && "bg-accent/60")}
              >
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-xs font-medium leading-5 text-foreground">
                    {o.label}
                  </span>
                  {o.description ? (
                    <span className="mt-0.5 block truncate text-[10px] leading-4 text-muted-foreground">
                      {o.description}
                    </span>
                  ) : null}
                </span>
                {selected && <Check size={14} className="shrink-0 text-primary" />}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
