import { Component, type ErrorInfo, type ReactNode } from "react";

/**
 * 顶层错误边界（白屏兜底）。
 *
 * 为什么必须有：本项目**没有**任何 Error Boundary，React 渲染期一旦抛异常，
 * 整棵子树会被卸载 → 整个窗口变成一片空白，用户只看到「白屏」而拿不到任何线索
 * （这正是「点配置厂商变白屏」这类问题的观感）。
 *
 * 策略：
 * - 捕获后把错误信息 + 组件栈**显示在界面上**，而不是静默白屏；
 * - 提供「重试」按钮（重置 state 重新挂载子树）与「复制错误」按钮，
 *   用户可以直接把信息反馈给我们；
 * - 不做自动上报（本地工具，无远端）。
 *
 * 注意：错误边界只捕获**渲染期 / 生命周期 / 构造函数**里的异常，
 * 事件处理器、异步回调里的异常捕获不到 —— 但那些也不会导致白屏，
 * 因为 React 不会因它们卸载树。
 */
interface State {
  error: Error | null;
  info: ErrorInfo | null;
}

export class ErrorBoundary extends Component<{ children: ReactNode }, State> {
  state: State = { error: null, info: null };

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // 同时打到控制台，方便开发期在 DevTools 里看到完整栈
    // eslint-disable-next-line no-console
    console.error("[ErrorBoundary] 渲染期异常:", error, info.componentStack);
    this.setState({ error, info });
  }

  private reset = () => {
    this.setState({ error: null, info: null });
  };

  private copy = () => {
    const { error, info } = this.state;
    const text = [
      `Error: ${error?.message ?? "(unknown)"}`,
      "",
      String(error?.stack ?? ""),
      "",
      "Component stack:",
      String(info?.componentStack ?? ""),
    ].join("\n");
    void navigator.clipboard.writeText(text).catch(() => {});
  };

  render() {
    const { error, info } = this.state;
    if (!error) return this.props.children;

    return (
      <div
        style={{
          padding: 16,
          fontFamily: "var(--font-sans, system-ui)",
          color: "var(--color-text-primary, #1a1a1a)",
        }}
      >
        <div style={{ fontSize: 14, fontWeight: 500, marginBottom: 6 }}>
          界面渲染出错，已阻止白屏
        </div>
        <div
          style={{
            fontSize: 12,
            color: "var(--color-text-secondary, #666)",
            marginBottom: 10,
            lineHeight: 1.6,
          }}
        >
          下面是具体错误信息，可点击「复制错误」反馈。
        </div>
        <pre
          style={{
            fontSize: 11,
            lineHeight: 1.5,
            whiteSpace: "pre-wrap",
            wordBreak: "break-all",
            background: "var(--color-background-secondary, #f5f5f5)",
            border: "1px solid var(--color-border-tertiary, #e0e0e0)",
            borderRadius: 8,
            padding: 10,
            maxHeight: 320,
            overflow: "auto",
            fontFamily: "var(--font-mono, monospace)",
          }}
        >
          {error.message}
          {"\n\n"}
          {error.stack}
          {info?.componentStack ? `\n\nComponent stack:${info.componentStack}` : ""}
        </pre>
        <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
          <button
            type="button"
            onClick={this.reset}
            style={{
              height: 28,
              padding: "0 12px",
              fontSize: 12,
              borderRadius: 6,
              border: "1px solid var(--color-border-secondary, #ccc)",
              background: "var(--color-background-primary, #fff)",
              cursor: "pointer",
            }}
          >
            重试
          </button>
          <button
            type="button"
            onClick={this.copy}
            style={{
              height: 28,
              padding: "0 12px",
              fontSize: 12,
              borderRadius: 6,
              border: "1px solid var(--color-border-secondary, #ccc)",
              background: "var(--color-background-primary, #fff)",
              cursor: "pointer",
            }}
          >
            复制错误
          </button>
        </div>
      </div>
    );
  }
}
