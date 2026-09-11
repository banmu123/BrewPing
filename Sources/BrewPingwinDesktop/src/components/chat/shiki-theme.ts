import { createCssVariablesTheme, type ThemeRegistrationAny } from "shiki";

/// Shiki CSS 变量主题（渲染栈规格 §5.2）：
/// token 颜色输出为 var(--brewping-shiki-*)，与应用主题解耦——
/// 换主题零重高亮，颜色由 app.css 里的变量即时生效。
export const brewpingShikiTheme: ThemeRegistrationAny = createCssVariablesTheme({
  name: "brewping-css-variables",
  variablePrefix: "--brewping-shiki-",
});

/// Streamdown 的 shikiTheme 是 [light, dark] 双槽；本应用恒为拿铁浅色，双槽同一份。
export const streamdownShikiTheme: [ThemeRegistrationAny, ThemeRegistrationAny] = [
  brewpingShikiTheme,
  brewpingShikiTheme,
];
