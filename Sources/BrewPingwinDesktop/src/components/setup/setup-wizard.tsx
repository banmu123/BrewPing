// ─── Setup Wizard（引导页，五步：welcome → check → node → agents → done）──────
//
// 对齐 macOS SetupWizardView（ed2d2f5 + 1c66bf5 + 52ce1fa）：
// - 检测复用设置 → 环境同一后端（checkEnvironment / installedNodeVersions）；
// - **绝不自动安装**：只提供官方链接 + 复制安装命令 + 「重新检测」；
// - 决策模型 evaluateSetup：nodeOK = installed && compatible（≥22）；
//   !nodeOK → needNode；有已装 agent → ready；否则 needAgents；
// - done 双变体（就绪清单 / 未装 agent）由同一决策驱动；
// - Skip 后主界面只留轻量横幅（App.tsx），设置 → 通用可重新运行。
//
// Windows 平台差异：
// - Node 版本切换走 nvm-windows 的 `nvm use`（重建 NVM_SYMLINK，即全局默认），
//   没有 macOS 的 default 别名语义；isDefault = 符号链接当前指向的版本；
// - 版本来源只有 "nvm" | "system"（无 Homebrew 分支，文案键保留以对齐 macOS）。

import { useCallback, useState } from "react";
import { Check, Circle, Copy, ExternalLink, Loader2 } from "lucide-react";
import {
  checkEnvironment,
  getStatus,
  installedNodeVersions,
  switchNodeDefault,
} from "../../api/tauri";
import type {
  AgentCliStatus,
  EnvironmentStatus,
  NodeInstallOption,
} from "../../api/types";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";
import {
  SetupState,
  evaluateSetup,
  type SetupDecision,
} from "../../lib/setup-state";

type Step = "welcome" | "check" | "node" | "agents" | "done";

/// 各 Agent 的官方文档链接（对齐 macOS AgentInstallInfo）。
const AGENT_DOCS: Record<string, string> = {
  opencode: "https://opencode.ai/docs",
  "claude-code": "https://docs.anthropic.com/en/docs/claude-code",
  codex: "https://github.com/openai/codex",
  pi: "https://www.npmjs.com/package/@earendil-works/pi-coding-agent",
};

/** 官方推荐安装命令（后端 methods 里 recommended 优先；无则第一条）。 */
function recommendedCommand(agent: AgentCliStatus): string | null {
  const method = agent.methods.find((m) => m.recommended) ?? agent.methods[0];
  return method?.display ?? null;
}

/** 从 userAgent 提取 Windows 版本描述（引导页展示用，非严格判定）。 */
function osLabel(): string {
  if (typeof navigator === "undefined") return "Windows";
  const m = /Windows NT ([\d.]+)/.exec(navigator.userAgent);
  if (!m) return "Windows";
  return m[1].startsWith("10.") ? "Windows 10 / 11" : "Windows";
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
      return true;
    } catch {
      return false;
    }
  }
}

type RowTone = "success" | "warning" | "optional" | "unavailable";

const ROW_BADGE: Record<RowTone, { variant: "success" | "warning" | "secondary" | "outline"; key: "swStatusReady" | "swStatusNeedsSetup" | "swStatusOptional" | "swStatusUnavailable" }> = {
  success: { variant: "success", key: "swStatusReady" },
  warning: { variant: "warning", key: "swStatusNeedsSetup" },
  optional: { variant: "secondary", key: "swStatusOptional" },
  unavailable: { variant: "outline", key: "swStatusUnavailable" },
};

export function SetupWizard({ onFinish }: { onFinish: () => void }) {
  const { t } = useI18n();
  const [step, setStep] = useState<Step>("welcome");
  const [env, setEnv] = useState<EnvironmentStatus | null>(null);
  const [nodeVersions, setNodeVersions] = useState<NodeInstallOption[]>([]);
  const [checking, setChecking] = useState(false);
  const [serviceReady, setServiceReady] = useState<boolean | null>(null);
  const [copiedAgentId, setCopiedAgentId] = useState<string | null>(null);
  const [switchingVersion, setSwitchingVersion] = useState<string | null>(null);
  const [switchError, setSwitchError] = useState<string | null>(null);

  const decision: SetupDecision | null = env ? evaluateSetup(env) : null;
  const nodeOK = env?.node.installed === true && env.node.compatible === true;
  const installedAgents = env?.agents.filter((a) => a.installed) ?? [];

  const scan = useCallback(async () => {
    setChecking(true);
    try {
      const status = await checkEnvironment();
      setEnv(status);
      try {
        setNodeVersions(await installedNodeVersions(status.node.path));
      } catch {
        setNodeVersions([]);
      }
      SetupState.saveSnapshot(status);
    } catch {
      /* 检测失败保持原状，用户可再点「重新检测」 */
    } finally {
      setChecking(false);
    }
  }, []);

  const startScan = useCallback(() => {
    setStep("check");
    void scan();
    // HTTP 服务的存活由这次 invoke 本身证明（能应答 = 服务在跑）
    void getStatus()
      .then(() => setServiceReady(true))
      .catch(() => setServiceReady(false));
  }, [scan]);

  const skip = () => {
    SetupState.markSkipped();
    onFinish();
  };
  const complete = () => {
    SetupState.markCompleted();
    onFinish();
  };

  const switchNode = async (version: string) => {
    if (switchingVersion) return;
    setSwitchingVersion(version);
    setSwitchError(null);
    try {
      await switchNodeDefault(version);
      setSwitchingVersion(null);
      await scan();
    } catch {
      setSwitchingVersion(null);
      setSwitchError(t("swSwitchFailed"));
    }
  };

  const copyCommand = async (agent: AgentCliStatus) => {
    const cmd = recommendedCommand(agent);
    if (!cmd) return;
    if (await copyText(cmd)) {
      setCopiedAgentId(agent.id);
      window.setTimeout(() => setCopiedAgentId((cur) => (cur === agent.id ? null : cur)), 1500);
    }
  };

  // ─── 通用小件 ───────────────────────────────────────────────────────────────

  const column = (children: React.ReactNode) => (
    <div className="flex w-full max-w-[560px] flex-col">{children}</div>
  );

  const stepHeader = (title: string, subtitle?: string | null) => (
    <div className="flex flex-col gap-1">
      <h2 className="text-xl font-semibold tracking-tight text-foreground">{title}</h2>
      {subtitle && <p className="text-xs text-muted-foreground">{subtitle}</p>}
    </div>
  );

  const statusRow = (
    label: string,
    tone: RowTone,
    detail: string | null,
    why?: string | null,
  ) => {
    const badge = ROW_BADGE[tone];
    return (
      <div className="flex flex-col gap-0.5 border-b border-border/40 pb-2">
        <div className="flex items-center gap-2">
          <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
            {label}
          </span>
          {detail && (
            <span className="min-w-0 truncate font-mono text-[11px] text-muted-foreground">
              {detail}
            </span>
          )}
          <Badge variant={badge.variant} className="shrink-0">
            {t(badge.key)}
          </Badge>
        </div>
        {why && <p className="text-[10px] leading-relaxed text-muted-foreground">{why}</p>}
      </div>
    );
  };

  // ─── welcome ───────────────────────────────────────────────────────────────

  const welcomeStep = (
    <div className="flex max-w-[320px] flex-col items-center gap-5 text-center">
      <span className="text-4xl">☕</span>
      <h1 className="text-xl font-semibold tracking-tight text-foreground">
        {t("swWelcomeTitle")}
      </h1>
      <p className="text-xs leading-relaxed text-muted-foreground">{t("swWelcomeSubtitle")}</p>
      <div className="mt-2 flex w-full flex-col gap-2">
        <Button className="w-full" onClick={startScan}>
          {t("swGetStarted")}
        </Button>
        <Button variant="ghost" className="w-full" onClick={skip}>
          {t("swSkipForNow")}
        </Button>
      </div>
    </div>
  );

  // ─── check ─────────────────────────────────────────────────────────────────

  const checkStep = column(
    <>
      {stepHeader(t("swStepCheck"), checking ? t("swChecking") : null)}
      <div className="mt-4 flex flex-col gap-2.5">
        {statusRow(t("swRowOS"), "success", osLabel())}
        {statusRow(
          t("swRowNode"),
          env
            ? nodeOK
              ? "success"
              : "warning"
            : "unavailable",
          env?.node.version ? `v${env.node.version}` : null,
          env
            ? !env.node.installed
              ? t("swWhyNodeMissing")
              : !env.node.compatible
                ? t("swWhyNodeOld", { version: `v${env.node.version ?? "?"}`, n: 22 })
                : null
            : null,
        )}
        {statusRow(
          t("swRowNpm"),
          env?.npm.installed ? "success" : nodeOK ? "warning" : "unavailable",
          env?.npm.version ?? null,
          !env?.npm.installed ? t("swWhyNpmMissing") : null,
        )}
        {statusRow(
          t("swRowNvm"),
          env?.nvm.installed
            ? "success"
            : nodeOK
              ? "optional"
              : "warning",
          env?.nvm.version ?? null,
          !env?.nvm.installed
            ? nodeOK
              ? t("swNvmOptionalHint")
              : t("swWhyNvmMissing")
            : null,
        )}
        {statusRow(
          t("swRowBrewping"),
          serviceReady === null ? "unavailable" : serviceReady ? "success" : "warning",
          serviceReady ? t("swServiceReadyDetail") : null,
        )}
        {statusRow(
          t("swRowAgents"),
          installedAgents.length > 0 ? "success" : "warning",
          env ? t("swAgentsSummary", { n: installedAgents.length, total: env.agents.length }) : null,
        )}
      </div>
      <div className="mt-5 flex items-center gap-2">
        <Button onClick={() => setStep(decision === "needNode" ? "node" : "agents")} disabled={!env}>
          {t("swContinue")}
        </Button>
        <Button variant="outline" onClick={() => void scan()} disabled={checking}>
          {t("swCheckAgain")}
        </Button>
        <Button variant="ghost" onClick={skip} className="ml-auto">
          {t("swSkipForNow")}
        </Button>
      </div>
    </>,
  );

  // ─── node（对齐 52ce1fa 信息层级：可一键切换时，切换是主操作）────────────────

  const hasSwitchableNewer =
    nodeVersions.some((v) => v.compatible && v.source === "nvm" && !v.isDefault);

  const nodeStepTitle =
    env?.node.installed && !env.node.compatible ? t("swNodeUpdateTitle") : t("swNodeStepTitle");

  const nodeStatusBox = () => {
    if (env?.node.installed && env.node.compatible) {
      // 就绪态（切换成功 / 从本步返回）：绿色就绪框而非「未安装」报错
      return (
        <div className="rounded-lg border border-success/20 bg-success/8 px-3 py-2.5">
          <div className="flex items-center gap-1.5 text-success">
            <Check size={12} />
            <span className="text-xs font-medium">
              {t("swRowNode")} {env.node.version ? `v${env.node.version}` : ""}
            </span>
            <Badge variant="success" className="shrink-0">
              {t("swStatusReady")}
            </Badge>
          </div>
          <p className="mt-0.5 text-[10px] text-muted-foreground">{t("swReadySubtitle")}</p>
        </div>
      );
    }
    if (env?.node.installed) {
      return (
        <div className="rounded-lg border border-warning/20 bg-warning/8 px-3 py-2.5">
          <div className="flex items-center gap-1.5 text-warning">
            <Circle size={12} />
            <span className="text-xs font-medium">
              {t("swRowNode")} {env.node.version ? `v${env.node.version}` : ""}
            </span>
          </div>
          <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground">
            {t("swWhyNodeOld", { version: `v${env.node.version ?? "?"}`, n: 22 })}
          </p>
        </div>
      );
    }
    return (
      <div className="rounded-lg border border-warning/20 bg-warning/8 px-3 py-2.5">
        <div className="flex items-center gap-1.5 text-warning">
          <Circle size={12} />
          <span className="text-xs font-medium">{t("swRowNode")}</span>
        </div>
        <p className="mt-0.5 text-[10px] leading-relaxed text-muted-foreground">
          {t("swWhyNodeMissing")}
        </p>
      </div>
    );
  };

  const sourceLabel = (source: string) =>
    source === "nvm" ? "nvm" : source === "homebrew" ? t("swSourceHomebrew") : t("swSourceSystem");

  const nodeVersionsSection = (
    <>
      {nodeVersions.length > 0 && (
        <>
          {hasSwitchableNewer && (
            <p className="pt-2.5 text-xs text-foreground/85">{t("swNodeSwitchIntro")}</p>
          )}
          <p className="pt-4 text-[11px] font-medium text-foreground/85">
            {t("swNodeVersionsTitle")}
          </p>
          <div className="mt-2 overflow-hidden rounded-lg border border-border">
            {nodeVersions.map((option) => (
              <div
                key={option.path}
                className="flex items-center gap-2 border-b border-border/40 px-2.5 py-1.5 last:border-b-0"
              >
                <span
                  className={cn(
                    "font-mono text-[11px]",
                    option.isActive ? "text-primary" : "text-foreground",
                  )}
                >
                  v{option.version}
                </span>
                {option.isDefault && (
                  <Badge variant="secondary" className="shrink-0">
                    {t("swNodeDefaultBadge")}
                  </Badge>
                )}
                {option.isActive && (
                  <Badge variant="success" className="shrink-0">
                    {t("swNodeActiveBadge")}
                  </Badge>
                )}
                {!option.compatible && (
                  <Badge variant="warning" className="shrink-0">
                    {t("swStatusNeedsSetup")}
                  </Badge>
                )}
                <span className="ml-auto min-w-0 shrink-0 text-[9px] text-muted-foreground/70">
                  {sourceLabel(option.source)}
                </span>
                {switchingVersion === option.version ? (
                  <span className="flex shrink-0 items-center gap-1 text-[10px] text-muted-foreground">
                    <Loader2 size={10} className="animate-spin" />
                    {t("swSwitching")}
                  </span>
                ) : option.source === "nvm" && !option.isDefault ? (
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-6 px-2 text-[10px]"
                    disabled={switchingVersion !== null}
                    onClick={() => void switchNode(option.version)}
                  >
                    {t("swNodeUse")}
                  </Button>
                ) : option.isDefault ? (
                  <span className="shrink-0 text-[10px] text-muted-foreground">
                    {t("swNodeInUse")}
                  </span>
                ) : null}
              </div>
            ))}
          </div>
          <p className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground/80">
            {t("swSwitchHint")}
          </p>
          {switchError && (
            <p className="mt-1 text-[10px] text-destructive">{switchError}</p>
          )}
        </>
      )}
    </>
  );

  const nodeStep = column(
    <>
      {stepHeader(nodeStepTitle, checking ? t("swChecking") : null)}
      <div className="mt-4 flex flex-col">
        {nodeStatusBox()}
        {nodeVersionsSection}
        {nodeVersions.length > 0 && (
          <p className="pt-4 text-[11px] font-medium text-foreground/85">{t("swManualInstall")}</p>
        )}
        <p className="pt-1.5 text-xs leading-relaxed text-muted-foreground">
          {t("swNodeStepHint")}
        </p>
        <div className="flex max-w-[320px] flex-col gap-2 pt-3">
          <Button
            variant="outline"
            onClick={() => window.open("https://github.com/coreybutler/nvm-windows", "_blank")}
          >
            <ExternalLink size={13} />
            {t("swOpenNvmGuide")}
          </Button>
          <Button
            variant="outline"
            onClick={() => window.open("https://nodejs.org/en/download", "_blank")}
          >
            <ExternalLink size={13} />
            {t("swOpenNodeDownload")}
          </Button>
        </div>
      </div>
      <div className="mt-5 flex items-center gap-2">
        <Button onClick={() => setStep("agents")} disabled={!nodeOK || checking}>
          {t("swContinue")}
        </Button>
        <Button variant="outline" onClick={() => setStep("check")}>
          {t("swBack")}
        </Button>
        <Button variant="outline" onClick={() => void scan()} disabled={checking}>
          {t("swCheckAgain")}
        </Button>
        <Button variant="ghost" onClick={skip} className="ml-auto">
          {t("swSkipForNow")}
        </Button>
      </div>
    </>,
  );

  // ─── agents ────────────────────────────────────────────────────────────────

  const agentCard = (agent: AgentCliStatus) => {
    const cmd = recommendedCommand(agent);
    const docs = AGENT_DOCS[agent.id];
    return (
      <div key={agent.id} className="rounded-lg border border-border bg-card p-3">
        <div className="flex items-center gap-2">
          <span className="text-xs font-semibold text-foreground">{agent.name}</span>
          {agent.installed ? (
            <>
              <Check size={12} className="text-success" />
              {agent.version && (
                <span className="font-mono text-[11px] text-muted-foreground">
                  v{agent.version}
                </span>
              )}
            </>
          ) : (
            <Badge variant="warning" className="shrink-0">
              {t("swAgentNotInstalled")}
            </Badge>
          )}
        </div>
        {agent.path && (
          <p className="mt-1 truncate font-mono text-[11px] text-muted-foreground/70">
            {agent.path}
          </p>
        )}
        {!agent.installed && (
          <div className="mt-2 flex flex-col gap-1.5">
            <div className="flex items-center gap-1.5">
              <code className="min-w-0 flex-1 truncate rounded-md border border-border bg-secondary/60 px-2 py-1 font-mono text-[11px] text-foreground">
                {cmd ?? "—"}
              </code>
              <Button variant="outline" size="sm" className="h-6 shrink-0 px-2 text-[10px]" onClick={() => void copyCommand(agent)}>
                <Copy size={10} />
                {copiedAgentId === agent.id ? t("swCopied") : t("swCopyCommand")}
              </Button>
            </div>
            {docs && (
              <Button
                variant="ghost"
                size="sm"
                className="h-6 w-fit px-1.5 text-[10px] text-muted-foreground"
                onClick={() => window.open(docs, "_blank")}
              >
                <ExternalLink size={10} />
                {t("swOpenDocs")}
              </Button>
            )}
          </div>
        )}
      </div>
    );
  };

  const agentsStep = column(
    <>
      {stepHeader(t("swAgentsStepTitle"), checking ? t("swChecking") : null)}
      <p className="mt-1.5 text-xs leading-relaxed text-muted-foreground">{t("swAgentsStepHint")}</p>
      <div className="mt-3 flex flex-col gap-2">
        {env?.agents.map(agentCard)}
      </div>
      <div className="mt-5 flex items-center gap-2">
        <Button onClick={() => setStep("done")} disabled={!env}>
          {t("swContinue")}
        </Button>
        <Button variant="outline" onClick={() => setStep(nodeOK ? "node" : "check")}>
          {t("swBack")}
        </Button>
        <Button variant="outline" onClick={() => void scan()} disabled={checking}>
          {t("swCheckAgain")}
        </Button>
        <Button variant="ghost" onClick={skip} className="ml-auto">
          {t("swSkipForNow")}
        </Button>
      </div>
    </>,
  );

  // ─── done（双变体）─────────────────────────────────────────────────────────

  const doneReady = column(
    <div className="flex flex-col items-center gap-4 text-center">
      <Check size={34} className="text-success" strokeWidth={2.5} />
      <div className="flex flex-col gap-1">
        <h2 className="text-xl font-semibold tracking-tight text-foreground">{t("swReadyTitle")}</h2>
        <p className="text-xs text-muted-foreground">{t("swReadySubtitle")}</p>
      </div>
      <div className="flex w-full max-w-[320px] flex-col gap-1 text-left">
        {[
          env?.node.version ? `${t("swRowNode")} v${env.node.version}` : t("swRowNode"),
          env?.npm.version ? `npm v${env.npm.version}` : "npm",
          t("swRowBrewping"),
          ...installedAgents.map((a) => a.name),
        ].map((label) => (
          <div key={label} className="flex items-center gap-2 text-xs text-foreground">
            <Check size={12} className="shrink-0 text-success" />
            <span className="min-w-0 truncate">{label}</span>
          </div>
        ))}
      </div>
      <Button className="mt-2 w-full max-w-[320px]" onClick={complete}>
        {t("swStartBrewping")}
      </Button>
    </div>,
  );

  const doneNoAgents = column(
    <div className="flex flex-col items-center gap-4 text-center">
      <Circle size={34} className="text-muted-foreground/50" strokeWidth={2.5} />
      <div className="flex flex-col gap-1">
        <h2 className="text-xl font-semibold tracking-tight text-foreground">{t("swNoAgentsTitle")}</h2>
        <p className="text-xs leading-relaxed text-muted-foreground">{t("swNoAgentsSubtitle")}</p>
      </div>
      <div className="mt-2 flex w-full max-w-[320px] flex-col gap-2">
        <Button variant="outline" className="w-full" onClick={() => setStep("agents")}>
          {t("swInstallAgent")}
        </Button>
        <Button variant="ghost" className="w-full" onClick={skip}>
          {t("swSkipForNow")}
        </Button>
      </div>
    </div>,
  );

  const doneStep = decision === "ready" ? doneReady : doneNoAgents;

  // ─── 组装 ──────────────────────────────────────────────────────────────────

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-background p-6">
      {step === "welcome"
        ? welcomeStep
        : step === "check"
          ? checkStep
          : step === "node"
            ? nodeStep
            : step === "agents"
              ? agentsStep
              : doneStep}
    </div>
  );
}
