import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { zh, en as en_dict, type DictKey } from "./locales";

// ─── 轻量 i18n（React Context 方案）──────────────────────────────────────────
// - langMode：用户选择（system / zh / en），持久化到 localStorage，刷新后保持；
// - locale：解析后的实际语言（system → navigator.language 探测，不在支持
//   范围内回落英文）；
// - 切换 = 改 Context state → 全树重渲染，实时生效，无需刷新页面。

export type LangMode = "system" | "zh" | "en";
/** 支持的语言集合（system 探测结果必须落在这个集合里）。 */
const SUPPORTED: Array<"zh" | "en"> = ["zh", "en"];
const STORAGE_KEY = "brewping.langMode";

/** 系统语言探测：zh* 前缀 → 中文，其余（含未识别）一律英文。 */
function detectSystemLang(): "zh" | "en" {
  const raw =
    typeof navigator !== "undefined" ? navigator.language : "en";
  const tag = (raw ?? "").toLowerCase();
  for (const s of SUPPORTED) {
    if (tag === s || tag.startsWith(`${s}-`) || tag.startsWith(`${s}_`)) return s;
  }
  return "en";
}

function loadLangMode(): LangMode {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    if (v === "zh" || v === "en" || v === "system") return v;
  } catch {
    /* localStorage 不可用时静默回落 */
  }
  return "system";
}

interface I18nContextValue {
  /** 用户选择的语言模式（含"跟随系统"）。 */
  langMode: LangMode;
  setLangMode: (mode: LangMode) => void;
  /** 解析后的实际语言（词典/日期格式化都用它）。 */
  locale: "zh" | "en";
  /** 取文案；支持 {name} 插值。 */
  t: (key: DictKey, params?: Record<string, string | number>) => string;
}

const I18nContext = createContext<I18nContextValue | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [langMode, setLangModeState] = useState<LangMode>(loadLangMode);
  // 系统语言只在装载时探测一次（运行中改系统语言本就需重启应用才一致）。
  const systemLang = useMemo(detectSystemLang, []);
  const locale = langMode === "system" ? systemLang : langMode;

  const setLangMode = useCallback((mode: LangMode) => {
    setLangModeState(mode);
    try {
      localStorage.setItem(STORAGE_KEY, mode);
    } catch {
      /* 持久化失败不阻塞切换（本次会话仍生效） */
    }
  }, []);

  const t = useCallback(
    (key: DictKey, params?: Record<string, string | number>) => {
      const dict = locale === "zh" ? zh : en_dict;
      let s: string = dict[key] ?? zh[key] ?? key;
      if (params) {
        for (const [k, v] of Object.entries(params)) {
          // 不用 replaceAll（TS lib target < ES2021），split/join 等价且对任意字符串安全
          s = s.split(`{${k}}`).join(String(v));
        }
      }
      return s;
    },
    [locale],
  );

  const value = useMemo(
    () => ({ langMode, setLangMode, locale, t }),
    [langMode, setLangMode, locale, t],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

/** 组件内取 i18n 能力；必须在 I18nProvider 之下使用。 */
export function useI18n(): I18nContextValue {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used within <I18nProvider>");
  return ctx;
}

/** Intl.DateTimeFormat 用的 locale 标签（时间戳 / 过期时间等格式化统一走这里）。 */
export function intlLocale(locale: "zh" | "en"): string {
  return locale === "zh" ? "zh-CN" : "en-US";
}
