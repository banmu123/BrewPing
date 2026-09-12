import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { Check, Download, Loader2, RefreshCw, ArrowUpCircle } from "lucide-react";
import {
  checkEnvironment,
  getNodeVersions,
  installNvm,
  installNode,
  installAgentCli,
  updateAgentCli,
} from "../../api/tauri";
import type {
  AgentCliStatus,
  EnvironmentStatus,
  EnvSetupDone,
  EnvSetupLog,
  InstallMethodInfo,
  NodeVersionOption,
} from "../../api/types";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

// ─── 设置页「环境与 AI CLI」卡片 ───────────────────────────────────────────────
// 自包含数据源（挂载时 checkEnvironment + getNodeVersions），App 无需传 props。
//
// 安装任务的运行态与日志放**模块级**缓存：设置页是条件渲染，用户安装中途
// 切回对话再进设置会卸载/重挂本组件，闭包与 state 都会丢；模块级 Map/数组
// 让重挂后仍能还原「正在安装」与已有日志。安装本身在后端线程，不受影响。

/// taskId → 运行态（taskId: "nvm" | "node" | "cli:<agentId>" | "cli-upd:<agentId>"）。
const taskStates = new Map<string, { running: boolean; ok?: boolean }>();
/// 安装日志环形缓冲（含命令行与逐行输出，上限 300 行）。
const logBuffer: string[] = [];
const LOG_CAP = 300;

/// 检测结果缓存（模块级）：切走再切回**不重复检测**，展示上次结果，
/// 用户点「重新检测」才真正跑一轮（探测要 spawn 多个 --version，约 1-2s）。
let envCache: EnvironmentStatus | null = null;
let versionsCache: NodeVersionOption[] | null = null;

function pushLog(line: string) {
  logBuffer.push(line);
  if (logBuffer.length > LOG_CAP) logBuffer.splice(0, logBuffer.length - LOG_CAP);
}

export function EnvironmentCard() {
  const { t } = useI18n();
  const [env, setEnv] = useState<EnvironmentStatus | null>(null);
  const [checking, setChecking] = useState(true);
  const [versions, setVersions] = useState<NodeVersionOption[] | null>(null);
  /// 选中的 Node 版本（chips 的 value：具体版本号或 "custom"）。
  const [verSel, setVerSel] = useState("");
  const [customVer, setCustomVer] = useState("");
  /// 日志区展开 + 模块级缓冲的版本号（数组身份不变，靠计数触发重渲染）。
  const [logOpen, setLogOpen] = useState(false);
  const [logVersion, setLogVersion] = useState(0);
  /// 任务态快照计数（Map 非响应式，完成/启动时 bump 触发重算 busy；值本身不读）。
  const [, setTaskTick] = useState(0);
  const logRef = useRef<HTMLDivElement>(null);

  const busy = [...taskStates.values()].some((s) => s.running);

  // ── 数据加载 ────────────────────────────────────────────────────────────────

  const refresh = useCallback(async () => {
    setChecking(true);
    try {
      const status = await checkEnvironment();
      envCache = status;
      setEnv(status);
    } catch {
      setEnv(null);
    } finally {
      setChecking(false);
    }
  }, []);

  useEffect(() => {
    // 有缓存直接展示（切分类回来不重复探测），没有才首测
    if (envCache) {
      setEnv(envCache);
      setChecking(false);
    } else {
      void refresh();
    }
    if (versionsCache) {
      setVersions(versionsCache);
      setVerSel(
        versionsCache.find((v) => v.recommended)?.version ??
          versionsCache[0]?.version ??
          "custom",
      );
    } else {
      getNodeVersions()
        .then((list) => {
          versionsCache = list;
          setVersions(list);
          setVerSel(list.find((v) => v.recommended)?.version ?? list[0]?.version ?? "custom");
        })
        .catch(() => {
          setVersions([]);
          setVerSel("custom");
        });
    }
    // 重挂恢复：模块缓存里可能还有上次未结束的任务
    setTaskTick((n) => n + 1);
  }, [refresh]);

  // ── 后端事件：安装日志 / 任务结束 ──────────────────────────────────────────

  useEffect(() => {
    const unLog = listen<EnvSetupLog>("env-setup-log", (event) => {
      const d = event.payload;
      if (!d?.task || !d.line) return;
      pushLog(`[${d.task}] ${d.line}`);
      setLogVersion((v) => v + 1);
    });
    const unDone = listen<EnvSetupDone>("env-setup-done", (event) => {
      const d = event.payload;
      if (!d?.task) return;
      taskStates.set(d.task, { running: false, ok: d.ok });
      setLogOpen(true);
      setTaskTick((n) => n + 1);
    });
    return () => {
      unLog.then((fn) => fn());
      unDone.then((fn) => fn());
    };
  }, []);

  // 日志有新行且区开着 → 贴底
  useEffect(() => {
    if (logOpen && logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [logVersion, logOpen]);

  // ── 安装动作（进度看日志区；结束后重新检测） ────────────────────────────────

  const runTask = useCallback(
    async (taskId: string, action: () => Promise<unknown>) => {
      if (taskStates.get(taskId)?.running) return;
      taskStates.set(taskId, { running: true });
      setLogOpen(true);
      setTaskTick((n) => n + 1);
      try {
        await action();
        taskStates.set(taskId, { running: false, ok: true });
      } catch (e) {
        taskStates.set(taskId, { running: false, ok: false });
        pushLog(`[${taskId}] ✗ ${String(e)}`);
        setLogVersion((v) => v + 1);
      } finally {
        // 无论成败都刷新检测（安装半程失败也可能已装上一半）
        await refresh();
        setTaskTick((n) => n + 1);
      }
    },
    [refresh],
  );

  const handleInstallNvm = () =>
    runTask("nvm", () => installNvm()).then(() =>
      void getNodeVersions().then((list) => {
        versionsCache = list;
        setVersions(list);
      }),
    );

  const handleInstallNode = () => {
    const version = verSel === "custom" ? customVer.trim() : verSel;
    if (!version) return;
    return runTask("node", () => installNode(version));
  };

  const handleInstallCli = (agent: AgentCliStatus, method: InstallMethodInfo) =>
    runTask(`cli:${agent.id}`, () => installAgentCli(agent.id, method.id));

  const handleUpdateCli = (agentId: string) =>
    runTask(`cli-upd:${agentId}`, () => updateAgentCli(agentId));

  // ── 渲染辅助 ────────────────────────────────────────────────────────────────

  const node = env?.node;
  const verChips = (versions ?? []).slice(0, 6);
  const customActive = verSel === "custom";
  const nvmMissing = env != null && !env.nvm.installed;
  const cliTaskRunning = (id: string) => taskStates.get(`cli:${id}`)?.running === true;
  const cliUpdRunning = (id: string) => taskStates.get(`cli-upd:${id}`)?.running === true;

  return (
    <section className="rounded-lg border border-border bg-card p-3">
      {/* 标题行：右侧重新检测 */}
      <div className="mb-2 flex items-center justify-between">
        <div className="text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
          {t("env.title")}
        </div>
        <Button
          variant="ghost"
          size="sm"
          className="h-6 gap-1 px-2 text-[10px]"
          disabled={checking || busy}
          onClick={() => void refresh()}
        >
          {checking ? (
            <Loader2 size={11} className="animate-spin" />
          ) : (
            <RefreshCw size={11} />
          )}
          {checking ? t("env.checking") : t("env.refresh")}
        </Button>
      </div>

      {/* ── 环境状态四行（Node / npm / NVM / Python）── */}
      <dl className="grid grid-cols-[84px_1fr] gap-y-1.5 text-xs">
        <dt className="text-muted-foreground">{t("env.node")}</dt>
        <dd className="flex min-w-0 flex-wrap items-center gap-1.5">
          {node?.installed ? (
            <>
              <span className="select-text font-mono text-foreground">{node.version}</span>
              {node.source === "nvm" && (
                <span className="text-[9px] text-muted-foreground">({t("env.nodeSourceNvm")})</span>
              )}
              {node.compatible ? (
                <Badge variant="success" className="px-1.5 py-0 text-[9px]">
                  {t("env.nodeCompatible")}
                </Badge>
              ) : (
                <Badge variant="warning" className="px-1.5 py-0 text-[9px]">
                  {t("env.nodeTooOld")}
                </Badge>
              )}
            </>
          ) : (
            <Badge variant="warning" className="px-1.5 py-0 text-[9px]">
              {t("env.notInstalled")}
            </Badge>
          )}
        </dd>
        <dt className="text-muted-foreground">{t("env.npm")}</dt>
        <dd className="select-text truncate font-mono text-foreground">
          {env?.npm.installed ? env.npm.version : <span className="font-sans text-muted-foreground">{t("env.notInstalled")}</span>}
        </dd>
        <dt className="text-muted-foreground">{t("env.nvm")}</dt>
        <dd className="select-text truncate font-mono text-foreground">
          {env?.nvm.installed ? env.nvm.version : <span className="font-sans text-muted-foreground">{t("env.notInstalled")}</span>}
        </dd>
        <dt className="text-muted-foreground">{t("env.python")}</dt>
        <dd className="select-text truncate font-mono text-foreground">
          {env?.python.installed ? env.python.version : <span className="font-sans text-muted-foreground">{t("env.notInstalled")}</span>}
        </dd>
      </dl>

      {/* Node 缺失 / 过旧时的引导提示 */}
      {node && !node.installed && (
        <div className="mt-2 rounded-md bg-warning/10 px-2.5 py-1.5 text-[10px] leading-relaxed text-warning">
          {t("env.nodeMinHint", { n: 22 })}
        </div>
      )}
      {node?.installed && !node.compatible && node.version && (
        <div className="mt-2 rounded-md bg-warning/10 px-2.5 py-1.5 text-[10px] leading-relaxed text-warning">
          {t("env.nodeOldHint", { n: 22, version: node.version })}
        </div>
      )}

      {/* ── 第一步：安装 NVM（未装时显示）── */}
      {nvmMissing && (
        <div className="mt-3 border-t border-border pt-2.5">
          <div className="text-[11px] font-medium text-foreground/85">{t("env.nvmSection")}</div>
          <div className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground">
            {t("env.nvmHint")}
          </div>
          <Button
            variant="outline"
            size="sm"
            className="mt-1.5 h-7 gap-1 px-2.5 text-xs"
            disabled={busy}
            onClick={handleInstallNvm}
          >
            {taskStates.get("nvm")?.running ? (
              <Loader2 size={12} className="animate-spin" />
            ) : (
              <Download size={12} />
            )}
            {taskStates.get("nvm")?.running ? t("env.installing") : t("env.installNvm")}
          </Button>
        </div>
      )}

      {/* ── 第二步：经 NVM 安装 Node（版本选择 / 自定义）── */}
      <div className="mt-3 border-t border-border pt-2.5">
        <div className="text-[11px] font-medium text-foreground/85">{t("env.nodeSection")}</div>
        <div className="mt-1.5 flex flex-wrap items-center gap-1">
          {verChips.map((v) => {
            const label =
              v.major != null
                ? `v${v.version}${v.lts ? " LTS" : ""}`
                : v.version;
            return (
              <button
                key={v.version}
                type="button"
                title={v.ltsName ? `${t("env.versionLts")} · ${v.ltsName}` : v.version}
                onClick={() => setVerSel(v.version)}
                className={cn(
                  "rounded-full border px-2 py-0.5 font-mono text-[10px] transition-colors",
                  verSel === v.version
                    ? "border-primary/40 bg-primary/10 font-medium text-primary"
                    : "border-border text-muted-foreground hover:bg-accent hover:text-foreground",
                )}
              >
                {label}
              </button>
            );
          })}
          {/* 自定义版本：点开输入框 */}
          <button
            type="button"
            onClick={() => setVerSel("custom")}
            className={cn(
              "rounded-full border px-2 py-0.5 text-[10px] transition-colors",
              customActive
                ? "border-primary/40 bg-primary/10 font-medium text-primary"
                : "border-border text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
          >
            {t("env.versionCustom")}
          </button>
        </div>
        {customActive && (
          <input
            className="mt-1.5 h-7 w-full rounded-md border border-border bg-background px-2 font-mono text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40"
            placeholder={t("env.versionCustomPlaceholder")}
            value={customVer}
            onChange={(e) => setCustomVer(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && customVer.trim() && !busy) handleInstallNode();
            }}
          />
        )}
        <Button
          variant="default"
          size="sm"
          className="mt-1.5 h-7 gap-1 px-2.5 text-xs"
          disabled={busy || nvmMissing || (customActive && !customVer.trim())}
          title={nvmMissing ? t("env.nvmSection") : undefined}
          onClick={handleInstallNode}
        >
          {taskStates.get("node")?.running ? (
            <Loader2 size={12} className="animate-spin" />
          ) : (
            <Download size={12} />
          )}
          {taskStates.get("node")?.running ? t("env.installing") : t("env.installNode")}
        </Button>
      </div>

      {/* ── AI 智能体 CLI 列表 ── */}
      <div className="mt-3 border-t border-border pt-2.5">
        <div className="text-[11px] font-medium text-foreground/85">{t("env.cliSection")}</div>
        <div className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground">
          {t("env.cliHint")}
        </div>
        <div className="mt-1.5 flex flex-col gap-1.5">
          {(env?.agents ?? []).map((agent) => (
            <div key={agent.id} className="rounded-md border border-border/60 px-2.5 py-2">
              {/* Agent 行：名称 + 状态（已安装 → 版本 + 更新按钮） */}
              <div className="flex items-center gap-2">
                <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
                  {agent.name}
                </span>
                {agent.installed ? (
                  <>
                    <span className="flex shrink-0 items-center gap-1 text-[10px] text-success">
                      <Check size={11} />
                      {t("env.installed")}
                      {agent.version && (
                        <span className="select-text font-mono text-muted-foreground">
                          {agent.version}
                        </span>
                      )}
                    </span>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-6 shrink-0 gap-1 px-2 text-[10px]"
                      disabled={busy}
                      title={t("env.updateTitle")}
                      onClick={() => void handleUpdateCli(agent.id)}
                    >
                      {cliUpdRunning(agent.id) ? (
                        <Loader2 size={10} className="animate-spin" />
                      ) : (
                        <ArrowUpCircle size={10} />
                      )}
                      {cliUpdRunning(agent.id) ? t("env.installing") : t("env.update")}
                    </Button>
                  </>
                ) : null}
              </div>
              {/* 未安装：每种官方方式一行（blocked 时给出原因并禁用） */}
              {!agent.installed &&
                agent.methods.map((m) => {
                  const blockedText =
                    m.blocked === "node"
                      ? t("env.blockNode")
                      : m.blocked === "node-version"
                        ? t("env.blockNodeVersion", { n: m.minNodeMajor })
                        : m.blocked === "python"
                          ? t("env.blockPython")
                          : null;
                  const methodLabel =
                    m.id === "native"
                      ? t("env.cliMethodNative")
                      : m.id === "npm"
                        ? t("env.cliMethodNpm")
                        : t("env.cliMethodPip");
                  const methodDesc =
                    m.id === "native"
                      ? t("env.cliMethodNativeDesc")
                      : m.id === "npm"
                        ? t("env.cliMethodNpmDesc")
                        : t("env.cliMethodPipDesc");
                  return (
                    <div key={m.id} className="mt-1.5 flex items-center gap-2">
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5">
                          <span className="truncate text-[11px] text-foreground/85">
                            {methodLabel}
                          </span>
                          {m.recommended && (
                            <span className="shrink-0 rounded-full bg-primary/10 px-1.5 text-[9px] text-primary">
                              ★
                            </span>
                          )}
                        </div>
                        <div className="truncate text-[9px] text-muted-foreground/70">
                          {blockedText ?? methodDesc}
                        </div>
                      </div>
                      <Button
                        variant="outline"
                        size="sm"
                        className="h-6 shrink-0 gap-1 px-2 text-[10px]"
                        disabled={busy || !!blockedText}
                        title={blockedText ?? m.display}
                        onClick={() => void handleInstallCli(agent, m)}
                      >
                        {cliTaskRunning(agent.id) ? (
                          <Loader2 size={10} className="animate-spin" />
                        ) : (
                          <Download size={10} />
                        )}
                        {cliTaskRunning(agent.id) ? t("env.installing") : t("env.cliInstall")}
                      </Button>
                    </div>
                  );
                })}
            </div>
          ))}
        </div>
      </div>

      {/* ── 安装日志（流式；失败时自动展开）── */}
      {logBuffer.length > 0 && (
        <div className="mt-3 border-t border-border pt-2.5">
          <button
            type="button"
            className="flex w-full items-center gap-1 text-[10px] font-medium text-muted-foreground hover:text-foreground"
            onClick={() => setLogOpen((v) => !v)}
          >
            <span className="flex-1 text-left">{t("env.log")}</span>
            <span>{logOpen ? "−" : "+"}</span>
          </button>
          {logOpen && (
            <div
              ref={logRef}
              className="panel-scroll mt-1 max-h-40 overflow-y-auto rounded-md border border-border/60 bg-background p-2 font-mono text-[9px] leading-4 text-muted-foreground"
            >
              {logBuffer.map((line, i) => (
                <div
                  key={i}
                  className={cn(
                    "whitespace-pre-wrap break-all",
                    line.includes("✓") && "text-success",
                    line.includes("✗") && "text-destructive",
                  )}
                >
                  {line}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </section>
  );
}
