import { memo } from "react";
import { Streamdown } from "streamdown";
import type { Components } from "streamdown";
import remarkGfm from "remark-gfm";
import { createMathPlugin } from "@streamdown/math";
import { remarkLinkifyPlainUrls } from "./linkify-plain-urls";
import { streamdownShikiTheme } from "./shiki-theme";
import { cn } from "../../lib/utils";

// ─── 模块级单例（渲染栈规格红线：绝不在渲染函数里新建数组/对象） ──────────────

/// 数学插件（KaTeX），单例
const MATH_PLUGIN = createMathPlugin();

/// 控件开关（渲染栈规格 §7.3 策略：代码只复制不下载；表格菜单关）
const STREAMDOWN_CONTROLS = {
  code: { copy: true, download: false },
  table: false,
} as const;

/// remark 插件层（渲染栈规格 §3，顺序敏感：GFM → 裸 URL 自动链接）
const MARKDOWN_REMARK_PLUGINS = [remarkGfm, remarkLinkifyPlainUrls] as const;

/// 外链强制 target=_blank + rel 合入 noopener noreferrer（规格 §9 MarkdownExternalLink 语义）
function MarkdownExternalLink({
  href,
  children,
}: {
  href?: string;
  children?: React.ReactNode;
}) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer">
      {children}
    </a>
  );
}

/// 组件映射（渲染栈规格 §9）
const MARKDOWN_COMPONENTS: Components = {
  a: (props) => <MarkdownExternalLink href={props.href}>{props.children}</MarkdownExternalLink>,
  inlineCode: (props) => (
    // 凹陷感代码片（规格 §9 inlineCode）
    <code
      className="rounded-sm bg-code px-1 py-px font-mono text-[0.85em] ring-1 ring-inset ring-border/50"
    >
      {props.children}
    </code>
  ),
  table: (props) => (
    // 横向滚动 + 圆角边框（规格 §9 table）
    <div className="my-3 overflow-x-auto rounded-lg border border-border/70 bg-background">
      <table className="w-full border-collapse text-[0.92em]" {...props} />
    </div>
  ),
};

// ─── 字号系统（渲染栈规格 §10.3） ─────────────────────────────────────────────

export function markdownFontSizeStyle(fontSize: number): React.CSSProperties {
  return {
    fontSize: `${fontSize}px`,
    "--markdown-body-font-size": `${fontSize}px`,
    "--markdown-h1-font-size": `${fontSize + 4}px`,
    "--markdown-h2-font-size": `${fontSize + 2}px`,
    "--markdown-small-heading-font-size": `${Math.max(1, fontSize - 2)}px`,
  } as React.CSSProperties;
}

// ─── 数学定界符归一化（渲染栈规格 §6 第 1 步） ────────────────────────────────

function normalizeTexMathDelimiters(text: string): string {
  return text
    .replace(/\\\((.+?)\\\)/gs, "$$$1$$")
    .replace(/\\\[(.+?)\\\]/gs, "\n$$\n$1\n$$\n");
}

// ─── 主渲染器 ────────────────────────────────────────────────────────────────

export interface MarkdownRendererProps {
  /// Markdown 原文（流式时传当前累积前缀即可）
  text: string;
  /// 字号像素（规格 §10.3：传导到 --markdown-* 变量）
  size?: number;
  className?: string;
  /// 流式进行中 → Streamdown isAnimating
  isStreaming?: boolean;
}

/// Streamdown 装配（渲染栈规格 §2）：
/// mode="streaming" 恒开；className="space-y-0" 覆盖默认间距（间距全走 .markdown-body）；
/// 块级间距/列表/引用样式统一在 app.css 的 .markdown-body（对应 MARKDOWN_BASE_CLASSNAME，
/// 整段搬移不拆抄——规格红线 §13.3）。
export const MarkdownRenderer = memo(function MarkdownRenderer({
  text,
  size = 14,
  className,
  isStreaming = false,
}: MarkdownRendererProps) {
  return (
    <div className={cn("markdown-body", className)} style={markdownFontSizeStyle(size)}>
      <Streamdown
        mode="streaming"
        className="space-y-0"
        controls={STREAMDOWN_CONTROLS}
        isAnimating={isStreaming}
        lineNumbers={false}
        shikiTheme={streamdownShikiTheme}
        plugins={{ math: MATH_PLUGIN }}
        components={MARKDOWN_COMPONENTS}
        remarkPlugins={[...MARKDOWN_REMARK_PLUGINS]}
      >
        {normalizeTexMathDelimiters(text)}
      </Streamdown>
    </div>
  );
});
