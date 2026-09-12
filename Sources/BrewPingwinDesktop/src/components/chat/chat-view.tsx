import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import { ArrowUp } from "lucide-react";
import type { TranscriptEntry } from "../../api/types";
import { MarkdownRenderer } from "./markdown-renderer";
import { cn } from "../../lib/utils";
import { CONVERSATION_CONTENT_WIDTH_CLASS } from "../../lib/conversation-layout";
import { useI18n, intlLocale } from "../../i18n";

// ─── 消息模型：对话转录是权威数据源（方案 §6.3）──────────────────────────────

export interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "error" | "system";
  text: string;
  /** 消息时间（转录条目的 createdAtMs）；老数据兜底无时间。 */
  createdAtMs?: number;
}

/// 转录条目 → 渲染消息（当前唯一映射；system 条目原样透传为系统行）。
export function fromTranscript(entries: TranscriptEntry[]): ChatMessage[] {
  return entries.map((e) => ({
    id: e.id,
    role: e.role,
    text: e.text,
    createdAtMs: e.createdAtMs,
  }));
}

/** 时间戳文案（对齐参考样式「星期五 20:48」/ "Friday 20:48"），随语言切换。 */
function timeLabel(ms: number | undefined, locale: "zh" | "en"): string | null {
  if (!ms) return null;
  const d = new Date(ms);
  return d.toLocaleString(intlLocale(locale), {
    weekday: "long",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/// 老数据兜底：终端行 → 对话消息（方案 §6.3 保留，不再作为主数据源）。
export function buildMessages(
  lines: Array<{ id: number; text: string; type: string }>,
): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (const line of lines) {
    if (line.type === "system" && line.text.startsWith("> ")) {
      out.push({ id: String(line.id), role: "user", text: line.text.slice(2) });
    } else if (line.type === "error") {
      out.push({ id: String(line.id), role: "error", text: line.text });
    } else {
      const last = out[out.length - 1];
      if (last && last.role === "assistant") {
        last.text += "\n" + line.text;
      } else {
        out.push({ id: String(line.id), role: "assistant", text: line.text });
      }
    }
  }
  return out;
}

/// 从一组消息里推导会话标题（兜底用；权威标题在后端 transcript 的 title 里）。
export function deriveTitle(messages: ChatMessage[], emptyLabel = "空对话"): string {
  const firstUser = messages.find((m) => m.role === "user");
  const text = (firstUser?.text ?? "").trim().replace(/\s+/g, " ");
  if (!text) return emptyLabel;
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

// ─── 消息列表（当前对话与历史查看共用） ────────────────────────────────────────

export function MessageList({
  messages,
  isStreaming,
}: {
  messages: ChatMessage[];
  isStreaming: boolean;
}) {
  const { t, locale } = useI18n();
  const lastId = messages.length > 0 ? messages[messages.length - 1].id : "-1";
  return (
    <div className={CONVERSATION_CONTENT_WIDTH_CLASS}>
      {messages.map((msg) =>
        msg.role === "user" ? (
          <div key={msg.id} className="mb-4">
            {/* 时间戳 + 右对齐（参考截图：星期五 20:48 / Friday 20:48） */}
            {timeLabel(msg.createdAtMs, locale) && (
              <div className="mb-1 flex items-center justify-end gap-1.5 text-[10px] text-muted-foreground">
                <span>{timeLabel(msg.createdAtMs, locale)}</span>
                <span className="flex h-5 w-5 items-center justify-center rounded-full bg-primary/15 text-[9px] font-medium text-primary">
                  {t("chat.me")}
                </span>
              </div>
            )}
            <div className="flex justify-end">
              <div className="max-w-[85%] rounded-2xl rounded-br-md bg-secondary px-3.5 py-2.5 text-sm leading-relaxed text-secondary-foreground select-text whitespace-pre-wrap break-words">
                {msg.text}
              </div>
            </div>
          </div>
        ) : msg.role === "error" ? (
          <div
            key={msg.id}
            className="mb-3 select-text font-mono text-xs text-warning break-all"
          >
            {msg.text}
          </div>
        ) : msg.role === "system" ? (
          <div
            key={msg.id}
            className="mb-3 text-center text-[10px] text-muted-foreground/70"
          >
            {msg.text}
          </div>
        ) : (
          // 助手消息：无头像无角标，Markdown 直接通栏排版（对齐参考截图）
          <div key={msg.id} className="mb-5">
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
  messages,
  agentName,
  isBusy,
  draft,
  onDraftChange,
  onSend,
  composerToolbar,
  composerTopBar,
}: {
  /** 权威转录（后端 conversation store），不再从终端行推导 */
  messages: ChatMessage[];
  agentName: string;
  /** 调度指针 / 终端状态驱动（方案 §6.4：latest_command_id 在飞 = busy） */
  isBusy: boolean;
  /** 输入草稿按对话隔离（App 层 Record<convId, string>），切换不丢失 */
  draft: string;
  onDraftChange: (text: string) => void;
  onSend: (text: string) => Promise<void>;
  /** composer 内的工具栏（agent / 模型 / 授权切换） */
  composerToolbar?: ReactNode;
  /** composer 卡片上方的独立条（工作目录选择），与卡片同宽 */
  composerTopBar?: ReactNode;
}) {
  const { t } = useI18n();
  const isStreaming =
    isBusy &&
    messages.length > 0 &&
    messages[messages.length - 1].role === "assistant";
  // agent 正在跑但还没有 assistant 输出 → 显示"正在思考"占位
  const showThinking =
    isBusy && (messages.length === 0 || messages[messages.length - 1].role !== "assistant");
  const scrollRef = useRef<HTMLDivElement>(null);

  // 新消息 / 流式增长 → 贴底
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, showThinking]);

  const canSend = draft.trim().length > 0 && !isBusy;

  const submit = async () => {
    const text = draft.trim();
    if (!text || isBusy) return;
    onDraftChange("");
    await onSend(text);
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* 消息滚动区：全幅容器（规格 §3 铁律 1），行内各自进列（铁律 2） */}
      {messages.length === 0 && !showThinking ? (
        <LandingGreeting agentName={agentName} />
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto py-4">
          <MessageList messages={messages} isStreaming={isStreaming} />
          {showThinking && (
            <div className="mb-4 flex items-center gap-2 text-xs text-muted-foreground">
              <span className="thinking-dot" />
              <span>{t("chat.thinking", { agent: agentName })}</span>
            </div>
          )}
        </div>
      )}

      {/* Composer 停靠区（§6.1 壳类）：一整块圆角卡片 = 输入区 + 内嵌工具栏行 */}
      <div className={COMPOSER_SHELL_CLASS}>
        <div className={CONVERSATION_CONTENT_WIDTH_CLASS}>
          {/* 卡片上方独立条：工作目录展示与选择 */}
          {composerTopBar}
          <div className={COMPOSER_CARD_CLASS}>
            <textarea
              value={draft}
              onChange={(e) => onDraftChange(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  void submit();
                }
              }}
              placeholder={t("chat.placeholder", { agent: agentName })}
              rows={2}
              className={COMPOSER_TEXTAREA_CLASS}
            />
            {/* 工具栏行：左侧 agent / 模型 / 授权，右侧终端开关 + 圆形发送钮 */}
            <div className="flex items-center gap-0.5 px-2 pb-2">
              {composerToolbar}
              <button
                type="button"
                aria-label={t("chat.send")}
                title={t("chat.sendTitle")}
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
  const { t } = useI18n();
  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-auto px-4">
      <div className="flex flex-1 flex-col items-center justify-center gap-5">
        <span className="text-3xl">☕</span>
        <h1 className="text-center text-4xl font-semibold tracking-tight text-foreground">
          {t("chat.standby", { agent: agentName })}
        </h1>
        <p className="text-center text-sm text-muted-foreground">
          {t("chat.landingHint")}
        </p>
      </div>
    </div>
  );
}
