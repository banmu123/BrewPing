import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { ErrorBoundary } from "./components/error-boundary";
import { I18nProvider } from "./i18n";
// Streamdown 控件（代码块复制按钮、表格菜单等）自带样式，必须全局装载一次
import "streamdown/styles.css";

// ErrorBoundary 放在最外层：任何渲染期异常都会被接住并显示错误详情，
// 而不是让 React 卸载整棵树造成「白屏」。I18nProvider 放其内层，
// 这样边界自身渲染时即使 i18n 出问题也仍有兜底（边界用硬编码中文）。
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary>
      <I18nProvider>
        <App />
      </I18nProvider>
    </ErrorBoundary>
  </React.StrictMode>,
);
