// ─── Setup Wizard：持久化 + 决策模型（对齐 macOS SetupState.swift）─────────────
//
// macOS 用 UserDefaults（brewping.setup.completed / skipped / snapshot）；
// Windows 前端等价物是 localStorage，键名保持同构，语义一一对应：
// - completed：用户在 done 步点过「开始使用」；
// - skipped：用户点过「暂时跳过」（主界面只留轻量横幅，可随时重跑）；
// - snapshot：最近一次扫描的环境快照（Node/npm 版本、NVM、已装 agent 清单）。

import type { EnvironmentStatus } from "../api/types";

export interface SetupSnapshot {
  nodeVersion: string | null;
  nodePath: string | null;
  npmVersion: string | null;
  nvmDetected: boolean;
  installedAgents: string[];
  checkedAtMs: number;
}

const COMPLETED_KEY = "brewping.setup.completed";
const SKIPPED_KEY = "brewping.setup.skipped";
const SNAPSHOT_KEY = "brewping.setup.snapshot";

function readFlag(key: string): boolean {
  try {
    return localStorage.getItem(key) === "1";
  } catch {
    return false;
  }
}

function writeFlag(key: string, value: boolean) {
  try {
    if (value) {
      localStorage.setItem(key, "1");
    } else {
      localStorage.removeItem(key);
    }
  } catch {
    /* localStorage 不可用时静默（本次会话仍生效） */
  }
}

export const SetupState = {
  isCompleted(): boolean {
    return readFlag(COMPLETED_KEY);
  },
  markCompleted() {
    writeFlag(COMPLETED_KEY, true);
    writeFlag(SKIPPED_KEY, false);
  },
  isSkipped(): boolean {
    return readFlag(SKIPPED_KEY);
  },
  markSkipped() {
    writeFlag(SKIPPED_KEY, true);
  },
  /** 重新运行引导（设置入口 / 横幅按钮）：清掉两个标记。 */
  reset() {
    writeFlag(COMPLETED_KEY, false);
    writeFlag(SKIPPED_KEY, false);
    try {
      localStorage.removeItem(SNAPSHOT_KEY);
    } catch {
      /* 忽略 */
    }
  },
  /** 启动时是否显示引导页（对齐 shouldShowOnLaunch）。 */
  shouldShowOnLaunch(): boolean {
    return !this.isCompleted() && !this.isSkipped();
  },
  saveSnapshot(env: EnvironmentStatus) {
    const snap: SetupSnapshot = {
      nodeVersion: env.node.version,
      nodePath: env.node.path,
      npmVersion: env.npm.version,
      nvmDetected: env.nvm.installed,
      installedAgents: env.agents.filter((a) => a.installed).map((a) => a.id),
      checkedAtMs: Date.now(),
    };
    try {
      localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snap));
    } catch {
      /* 快照丢失不影响功能 */
    }
  },
  loadSnapshot(): SetupSnapshot | null {
    try {
      const raw = localStorage.getItem(SNAPSHOT_KEY);
      return raw ? (JSON.parse(raw) as SetupSnapshot) : null;
    } catch {
      return null;
    }
  },
};

// ─── 决策模型（纯函数，对齐 macOS SetupWizardModel.evaluate）─────────────────
//
// nodeOK = node.installed && node.compatible（≥ 22，Claude Code npm 路线门槛）；
// !nodeOK → needNode；有已装 agent → ready；否则 needAgents。
// done 步的双变体与 check→node/agents 的走向都由这一个函数驱动。

export type SetupDecision = "ready" | "needNode" | "needAgents";

export function evaluateSetup(env: EnvironmentStatus): SetupDecision {
  const nodeOK = env.node.installed && env.node.compatible;
  if (!nodeOK) return "needNode";
  return env.agents.some((a) => a.installed) ? "ready" : "needAgents";
}
