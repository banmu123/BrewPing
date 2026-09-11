import { useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { ArrowUp } from "lucide-react";
import type { AgentTerminalState, OutputLine } from "../../api/types";
import { MarkdownRenderer } from "./markdown-renderer";
import { Badge } from "../ui/badge";
import { cn } from "../../lib/utils";
import { CONVERSATION_CONTENT_WIDTH_CLASS } from "../../lib/conversation-layout";

// ─── 消息模型：从终端输出行推导（单一数据源，不复制状态） ────────────────────

export interface ChatMessage {
  id: number;
  role: "user" | "assistant" | "error";
  text: string;
}

/// 终端行 → 对话消息：
/// - `> ` 开头的 system 行 = 用户消息（手机/手表/桌面发的指令）；
/// - error 行 = 错误系统消息；
/// - 其余连续行合并为一条助手消息（Markdown 增量渲染，流式观感来自轮询/事件刷新）。
export function buildMessages(lines: OutputLine[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (const line of lines) {
    if (line.type === "system" && line.text.startsWith("> ")) {
      out.push({ id: line.id, role: "user", text: line.text.slice(2) });
    } else if (line.type === "error") {
      out.push({ id: line.id, role: "error", text: line.text });
    } else {
      const last = out[out.length - 1];
      if (last && last.role === "assistant") {
        last.text += "\n" + line.text;
      } else {
        out.push({ id: line.id, role: "assistant", text: line.text });
      }
    }
  }
  return out;
}

/// 从一组消息里推导会话标题（「新对话」归档时用）。
export function deriveTitle(messages: ChatMessage[]): string {
  const firstUser = messages.find((m) => m.role === "user");
  const text = (firstUser?.text ?? "").trim().replace(/\s+/g, " ");
  if (!text) return "空对话";
  return text.length > 32 ? text.slice(0, 32) + "…" : text;
}

// ─── Composer 停靠壳（布局规格 §6.1：landing 与会话页共享同一份 shell 类，R12） ──
// 视觉参照 WorkBuddy：一整块圆角卡片，输入区在上、工具栏一行在下；
// 聚焦时边框转主色，卡片带柔和投影。

export const COMPOSER_SHELL_CLASS =
  "relative shrink-0 bg-background z-[var(--z-composer)] pb-3";

const COMPOSER_CARD_CLASS =
  "rounded-2xl border border-input-border bg-input-field shadow-panel " +
  "transition-colors focus-within:border-primary/45";

const COMPOSER_TEXTAREA_CLASS =
  "w-full resize-none bg-transparent px-4 pt-3.5 pb-1.5 min-h-[72px] max-h-44 " +
  "font-mono text-sm text-foreground placeholder:text-muted-foreground/70 " +
  "focus-visible:outline-none select-text";

/** 工具栏内的胶囊控件（select 外壳）：无边框、悬停浅棕面，视觉安静。 */
export const COMPOSER_PILL_CLASS =
  "flex h-7 items-center gap-1 rounded-lg px-2 text-xs text-muted-foreground " +
  "hover:bg-accent hover:text-foreground transition-colors cursor-pointer";

const COMPOSER_SELECT_CLASS =
  "max-w-40 cursor-pointer appearance-none bg-transparent text-xs text-current " +
  "focus-visible:outline-none";

export { COMPOSER_SELECT_CLASS };

// ─── 消息列表（当前对话与历史归档共用） ────────────────────────────────────────

export function MessageList({
  messages,
  agentName,
  isStreaming,
}: {
  messages: ChatMessage[];
  agentName: string;
  isStreaming: boolean;
}) {
  const lastId = messages.length > 0 ? messages[messages.length - 1].id : -1;
  return (
    <div className={CONVERSATION_CONTENT_WIDTH_CLASS}>
      {messages.map((msg) =>
        msg.role === "user" ? (
          <div key={msg.id} className="mb-3 flex justify-end">
            <div className="max-w-[85%] rounded-lg bg-secondary px-3 py-2 text-sm text-secondary-foreground select-text whitespace-pre-wrap break-words">
              {msg.text}
            </div>
          </div>
        ) : msg.role === "error" ? (
          <div
            key={msg.id}
            className="mb-3 select-text font-mono text-xs text-warning break-all"
          >
            {msg.text}
          </div>
        ) : (
          <div key={msg.id} className="mb-4">
            <div className="mb-1 flex items-center gap-1.5">
              <Badge variant="secondary" className="text-[10px]">
                {agentName}
              </Badge>
              {isStreaming && msg.id === lastId && (
                <span className="text-[10px] text-muted-foreground">
                  正在输出…
                </span>
              )}
            </div>
            <MarkdownRenderer
              text={msg.text}
              isStreaming={isStreaming && msg.id === lastId}
            />
          </div>
        ),
      )}
    </div>
  );
}

// ─── 对话视图 ────────────────────────────────────────────────────────────────

export function ChatView({
  terminal,
  agentName,
  onSend,
  composerToolbar,
}: {
  terminal: AgentTerminalState | null;
  agentName: string;
  onSend: (text: string) => Promise<void>;
  /** composer 内的工具栏（agent / 模型 / 授权切换） */
  composerToolbar?: ReactNode;
}) {
  const messages = useMemo(
    () => buildMessages(terminal?.outputLines ?? []),
    [terminal?.outputLines],
  );
  const isBusy = terminal?.status === "running";
  const isStreaming =
    isBusy &&
    messages.length > 0 &&
    messages[messages.length - 1].role === "assistant";
  // agent 正在跑但还没有 assistant 输出 → 显示"正在思考"占位
  const showThinking =
    isBusy && (messages.length === 0 || messages[messages.length - 1].role !== "assistant");
  const scrollRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState("");

  // 新消息 / 流式增长 → 贴底
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, showThinking]);

  const canSend = draft.trim().length > 0 && !isBusy;

  const submit = async () => {
    const text = draft.trim();
    if (!text || isBusy) return;
    setDraft("");
    await onSend(text);
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* 消息滚动区：全幅容器（规格 §3 铁律 1），行内各自进列（铁律 2） */}
      {messages.length === 0 && !showThinking ? (
        <LandingGreeting agentName={agentName} />
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto py-4">
          <MessageList messages={messages} agentName={agentName} isStreaming={isStreaming} />
          {showThinking && (
            <div className="mb-4 flex items-center gap-2 text-xs text-muted-foreground">
              <span className="thinking-dot" />
              <span>{agentName} 正在思考…</span>
            </div>
          )}
        </div>
      )}

      {/* Composer 停靠区（§6.1 壳类）：一整块圆角卡片 = 输入区 + 内嵌工具栏行 */}
      <div className={COMPOSER_SHELL_CLASS}>
        <div className={CONVERSATION_CONTENT_WIDTH_CLASS}>
          <div className={COMPOSER_CARD_CLASS}>
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  void submit();
                }
              }}
              placeholder={`给 ${agentName} 发消息，或从手机 / 手表发送…`}
              rows={2}
              className={COMPOSER_TEXTAREA_CLASS}
            />
            {/* 工具栏行：左侧 agent / 模型 / 授权，右侧终端开关 + 圆形发送钮 */}
            <div className="flex items-center gap-0.5 px-2 pb-2">
              {composerToolbar}
              <button
                type="button"
                aria-label="发送"
                title="发送（Enter）"
                disabled={!canSend}
                onClick={() => void submit()}
                className={cn(
                  "ml-auto flex h-8 w-8 shrink-0 items-center justify-center rounded-full transition-colors",
                  canSend
                    ? "bg-primary text-primary-foreground hover:bg-primary/90 shadow-xs"
                    : "bg-muted text-muted-foreground/60 cursor-not-allowed",
                )}
              >
                <ArrowUp size={16} strokeWidth={2.4} />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── 空态 Landing（布局规格 §6：问候区垂直居中 + composer 共享停靠壳） ─────────

function LandingGreeting({ agentName }: { agentName: string }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-auto px-4">
      <div className="flex flex-1 flex-col items-center justify-center gap-5">
        <span className="text-3xl">☕</span>
        <h1 className="text-center text-4xl font-semibold tracking-tight text-foreground">
          {agentName} 待命中
        </h1>
        <p className="text-center text-sm text-muted-foreground">
          在下方输入，或从 iPhone / Apple Watch 发送指令
        </p>
      </div>
    </div>
  );
}
