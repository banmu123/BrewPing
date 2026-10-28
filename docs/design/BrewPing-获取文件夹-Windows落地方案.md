# BrewPing Windows 版「获取文件夹」落地方案

> **一句话目标**：在 BrewPing 的 Windows 端（Tauri 2 + axum）实现与 Lody 等价的
> 「**浏览主机目录树 → 选中一个目录 → 设为某个 Agent 的工作目录**」效果，
> 由已配对的 iPhone / Watch 经局域网驱动，无需任何云端服务。

- **对标实现**：Lody 的 `LocalProjectControlService.listBrowseRoots` / `browseDirectory`
  （见 `.workbuddy/outputs/Lody-本地项目添加-本地与局域网规格.md` §6.5）
- **本文档范围**：Windows 桌面端（Rust 后端 + 可选前端）的全部改动
- **本文档不含**：iOS 侧 UI 实现（见 `BrewPing-获取文件夹-iOS与macOS落地方案.md`）
- **状态**：本方案为**只读分析产出**，尚未改动 BrewPing 任何源码

---

## 0. 一页速览

| 项目 | 结论 |
| --- | --- |
| Windows 端技术栈 | Tauri 2 + **axum 0.8**，HTTP 服务长在桌面进程内 |
| 是否需要改造 HTTP 层解析 query | **不需要**，axum 原生支持（macOS 端要补 3 个文件约 25 行） |
| 是否需要处理跨端权限弹窗 | **不需要**，Windows 无 TCC |
| 现状残留代码 | **无**，`grep folder\|workdir\|current_dir\|cwd` 在 Windows 源码中为空 |
| 鉴权是否需要改 | **不需要**，新路由天然落在 `auth_middleware` 保护范围内 |
| 新增文件 | 3 个（`folder_browser.rs` / `workdir_prefs.rs` / `folder_api.rs`） |
| 修改文件 | 5 个（`http_server.rs` / `lib.rs` / `mod.rs` / `Cargo.toml` / 可选前端 3 个） |
| **唯一"不做就白干"的点** | `Command::new` 共 **2 处**均无 `.current_dir()`，必须同步补 |
| **必须如实告知的能力缺口** | `opencode` 是 **stub，从不 spawn 进程** → workdir 对它无效 |
| 首要安全风险 | UNC 路径会触发 **SMB 凭据外泄**；junction 可绕过朴素路径白名单 |

---

## 1. 实现目标：什么是「与 Lody 相同的效果」

### 1.1 Lody 的完整效果链（四阶段）

```
阶段 A  daemon 启动与机器注册        ← BrewPing 无需（无 daemon，无工作区）
阶段 B  客户端判定「有没有可用机器」   ← BrewPing 无需（配对即机器）
阶段 C  目录浏览                     ← ★ 本方案主体
阶段 D  添加（落库与同步）            ← 塌缩为「写一个 JSON 键」
```

Lody 阶段 C 的用户可见效果，逐条列出（这就是要对齐的清单）：

1. 提供一个「根列表」（home 目录 + 盘符列表），默认从 home 开始浏览。
2. 面包屑 / `..` / 盘符可点击跳转；也可**手动输入绝对路径**直接跳转（Enter 提交 / Esc 取消）。
3. 只显示**目录**（文件被过滤），空目录也照常显示。
4. 默认**不显示隐藏目录**，需要一个开关切换。
5. 每个目录项带三个标记：`hidden`、`isSymlink`、`error:'unreadable'`。
6. 带 `hints.git` 的目录（含 `.git`）显示特殊徽章。
7. 大目录分页：单页默认 200 条、硬上限 1000 条，返回 `truncated` + `nextCursor`（游标就是 offset 字符串，**服务端无状态**）。
8. 排列顺序稳定（按名称）。
9. 「添加」按钮把**当前所在目录**直接设为目标，**没有独立的命名/确认步骤** —— 项目名由路径派生。
10. 重复添加不报错、不覆盖（幂等）。
11. 目录不可读时**仍然列出但置灰不可点**（而不是静默消失）。

### 1.2 塌缩到 BrewPing 后的形态

BrewPing 与 Lody 的结构差异，直接决定了简化幅度：

| Lody 概念 | BrewPing 对应物 | 处置 |
| --- | --- | --- |
| 多机器 / 工作区 / `machineId` | 一台已配对的 Windows 主机 | **删除**（配对即身份） |
| 机器可见性与 `canAddProjects` 归属判定 | 无 | **删除** |
| `prepare-add`（daemon 派生 ID）→ App 写 flock 行 | 无 CRDT | **合并为一步** |
| `local-project/prepare-add` + `flockRowPutIfAbsent` | 一次 `POST` 写 `workdirs.json` | **替换** |
| `LocalProjectId`（`sha256(realpath)[:24]`） | 不需要 | **删除**（键用 `agentId`） |
| 本地项目**集合**（多项目侧边栏） | BrewPing 侧边栏是 **Agent** 列表 | 塌缩为**每 Agent 一个**工作目录 |
| `daemon_unavailable` / `machine_mismatch` 自愈 | 无 daemon | **删除** |
| 云认证 / presence / Streams RPC | 无 | **删除** |
| `list-roots` 15s / `browse-dir` 30s 超时 | LAN 往返毫秒级 | **收紧到 5s / 8s**，但保留可配置 |

> **重要判断**：BrewPing 没有工作区、没有 CRDT、没有多客户端并发写，
> 所以 Lody 阶段 D 的**整个同步机制（flock 行 / 事务内读-判-写 / 回读校验）在 BrewPing 中不需要存在**。
> 真实语义被压缩为：「一次 POST → 写 `~/.brewping/workdirs.json` 的一个键」。

### 1.3 与 Lody 的逐项对照表

| Lody 能力 | BrewPing Windows 落地 | 是否等价 |
| --- | --- | --- |
| `getLocalProjectBrowsePlatform()` → `'win32'` | `std::env::consts::OS` → **`"windows"`** | 值不同，**必须显式对齐客户端**（见 §3.1 注） |
| `getPathSeparator()` → `'\'` | `std::path::MAIN_SEPARATOR_STR` | ✅ |
| `os.homedir()` realpath | `dirs::home_dir()` + `dunce::simplified` | ✅（多一步剥 `\\?\`） |
| `listWindowsDrives()` | `GetLogicalDrives` + `GetDriveTypeW` | ✅（**禁止 A–Z 探测**，见 §5.3） |
| `browseDirectory()` 10 条细节 | `folder_browser::browse_directory()` | ✅ 逐条对齐（见 §7.1） |
| 游标 = offset 字符串，服务端无状态 | 同 | ✅ |
| `realpath` 去重与软链判定 | `dunce::canonicalize` + `is_symlink()` | ⚠️ Windows 上 junction 也返回 `true`，见 §5.4 |
| `hidden = name.startsWith('.')` | 属性位 **∨** dotfile | ⚠️ **必须扩展**，见 §5.2 |
| `canReadDirectory()` | 打开目录句柄即丢弃 | ✅ 但**绝不读文件内容**，见 §5.4 |
| `registeredProjectId` 徽章 | 不需要（无项目集合）；改为在 `/api/agents` 回显 `workdir` | ⚠️ 语义替换 |
| 「添加」无命名步骤 | 同（路径即名字） | ✅ |

---

## 2. 现状取证（Windows 端）

### 2.1 模块与文件清单

路径前缀：`Sources/BrewPingwinDesktop/`

| 模块 | 文件 | 行数 | 与本方案的关系 |
| --- | --- | --- | --- |
| HTTP 服务 | `src-tauri/src/services/http_server.rs` | 1832 | ★ 路由 / 鉴权 / `submit_command` / **spawn 点 ①** |
| 桌面核心 | `src-tauri/src/lib.rs` | 804 | ★ `DesktopCore` / Tauri commands / **spawn 点 ②** |
| Agent 发现 | `src-tauri/src/services/agent_discovery.rs` | 332 | `AgentEntryApi`（要加 `workdir` 字段） |
| Agent 配置（只读） | `src-tauri/src/services/agent_config.rs` | 513 | 范式参考：只读、不伪造 |
| 终端状态 | `src-tauri/src/services/terminal_state.rs` | 215 | `failureReason` 观测面 |
| 配对与鉴权 | `src-tauri/src/services/pairing_store.rs` | 602 | 新路由免改，**GET 免 nonce** |
| **模型偏好** | `src-tauri/src/services/model_prefs.rs` | 154 | ★ **`workdir_prefs.rs` 的 1:1 模板** |
| 授权网关 | `src-tauri/src/services/approval_gate.rs` | 560 | — |
| 危险模式 | `src-tauri/src/services/danger_pattern.rs` | 284 | — |
| 设备身份 | `src-tauri/src/services/device_identity.rs` | 94 | `~/.brewping/device.json` |
| 局域网地址 | `src-tauri/src/services/lan_address.rs` | 84 | — |
| mDNS 广播 | `src-tauri/src/services/mdns_broadcast.rs` | 102 | `_brewping._tcp` TXT（可选扩展能力声明） |
| 托盘 | `src-tauri/src/services/tray.rs` | 232 | — |
| 模块注册 | `src-tauri/src/services/mod.rs` | 12 | ★ 新增模块要在此登记 |
| 前端主界面 | `src/App.tsx` | 508 | 单页 + 标签页，`panel` 状态控弹窗 |
| 前端 API 层 | `src/api/tauri.ts` | 138 | `invoke` 封装 |
| 前端类型 | `src/api/types.ts` | 91 | ★ `executable` 类型漂移需一并修正 |
| 样式 | `src/styles/app.css` | 676 | — |
| 依赖清单 | `src-tauri/Cargo.toml` | 37 | ★ 需补 2 个显式依赖 |
| Tauri 配置 | `src-tauri/tauri.conf.json` | 46 | 可选：原生选择器需配 capabilities |

**依赖现状（已核实 `Cargo.lock`）**：

- `dunce 1.0.5` —— **已在 lock 中**（作为传递依赖），但**未在 `Cargo.toml` 显式声明** → 需补
- `windows-sys` —— lock 中有 `0.45.0` 与 `0.52.0` 两个版本（传递依赖）→ 需显式声明 `0.52`
- `tauri-plugin-dialog` —— **不是依赖**（`grep -c` = 0）→ 走原生选择器需新增
- **无 `capabilities/` 源码目录**，只有 `gen/schemas/capabilities.json` 这类**自动生成的 schema** → 新增插件权限需要新建该目录

### 2.2 路由与鉴权现状

`http_server.rs:241-262` 的 `build_router`，全部 14 条路由：

| 方法 | 路径 | 鉴权 |
| --- | --- | --- |
| `GET` | `/api/status` | **公开**（`auth_middleware:227-228` 白名单） |
| `POST` | `/api/pair` | **公开**（同上） |
| `GET` | `/api/agents` | Bearer |
| `POST` | `/api/agents/default` | Bearer + Timestamp + Nonce |
| `GET` | `/api/agents/{agent_id}/models` | Bearer |
| `POST` | `/api/agents/models/default` | Bearer + Nonce |
| `POST` | `/api/message` | Bearer + Nonce |
| `GET` | `/api/message/{id}` | Bearer |
| `GET` / `POST` | `/api/approvals/mode` | Bearer / Bearer + Nonce |
| `GET` | `/api/approvals` | Bearer |
| `POST` | `/api/approvals/{id}` | Bearer + Nonce |
| `POST` | `/api/session/start` \| `/api/session/stop` | Bearer + Nonce |
| `POST` | `/api/discovery/refresh` | Bearer + Nonce |
| `*` | fallback | → 404 **JSON**（`handle_not_found:270-278`） |

**两个结构优势**（相对 macOS 那份方案）：

1. **`auth_middleware` 通过 `route_layer` 作用在全表上**（`http_server.rs:260`），
   新增路由**无需任何鉴权改动**即自动受保护。公开白名单是**精确路径匹配**，
   不会被 `/api/folders` 之类的新路径误放行。
2. **`PairingStore::authorize`（`pairing_store.rs:193-195`）对 `GET` 直接放行**
   （只需 Bearer，不校验 nonce），因为"`GET` 不产生副作用"。
   → 把**列目录设计成 `GET`**，iOS 侧天然免掉 nonce；只有**写操作**（设 workdir）才需要 nonce。

### 2.3 三个决定性事实

#### 事实 1 —— **唯一"不做就白干"的点**：`Command::new` 有两处，都没有 `.current_dir()`

| # | 位置 | 上下文 | 调用方 |
| --- | --- | --- | --- |
| ① | `http_server.rs:687-713` | `submit_command` → `tokio::task::spawn_blocking` 闭包 | 手机端 `POST /api/message`、审批放行 |
| ② | `lib.rs:464-529` | `send_command` → `tokio::task::spawn_blocking` 闭包 | **桌面 App 自己的输入框** |

两处当前代码形态一致：

```rust
let mut cmd = std::process::Command::new(&executable);
cmd.arg(&text);
// http_server 额外： if let Some(model) = &model_clone { cmd.arg("--model").arg(model); }
cmd.stdout(std::process::Stdio::piped())
   .stderr(std::process::Stdio::piped());
#[cfg(windows)]
{ /* PATH 注入 ~/.local/bin 与 ~/scoop/shims */ }
cmd.output()
```

**漏掉 `.current_dir()` 的后果不是报错，而是静默失败**：目录能浏览、能选中、能存进
`workdirs.json`，但 Agent **仍跑在进程当前目录**，且不报任何错。

进程当前目录**由启动方式决定、不可预期**：
- 从资源管理器双击启动 → 通常是 exe 所在目录
- 被服务 / 计划任务 / `lpCurrentDirectory=NULL` 的 `CreateProcess` 启动 → `C:\Windows\System32`

无论哪种都不是用户的项目目录。**两处必须一起改**，否则会出现"手机端生效、桌面端不生效"的分裂行为。

#### 事实 2 —— **`opencode` 是 stub，从不 spawn 进程**

| 位置 | 行为 |
| --- | --- |
| `http_server.rs:620-639` | `if aid == "opencode"` → 只 `append_line("Message sent to {}")` + `set_completed`，**不启动任何进程** |
| `lib.rs:382-416` | `send_command` 中同样的分支，同样不 spawn |

**因此设 workdir 目前只对 `claude-code` / `codex` / `aider` 真正生效。**
要让 `opencode` 也生效，需要先做 ConPTY（`CreatePseudoConsole`）——那是**独立工程**，
本方案**不包含**，且**不得在 UI 或文档中含糊过去**（否则用户会以为 opencode 的 workdir 坏了）。

建议：设置界面对 `opencode` 显示明确的"该 Agent 尚未支持工作目录"提示，
或在 `POST /api/agents/workdir` 对 `opencode` 返回 `400 unsupported_agent`。**二选一，不要沉默接受。**

#### 事实 3 —— **无任何残留实现**

```
grep -rn "folder|workdir|current_dir|cwd" Sources/BrewPingwinDesktop/src-tauri/src  → 空
grep -rn "folders|workdir" Sources/BrewPingwinDesktop/src                        → 空
```

→ **纯新建，没有半成品要绕**。`agent_config.rs` 已建立"只读、不改写 Agent 自身配置、
配置文件坏了就退化为空"的范式，直接沿用。

---

## 3. 接口契约（新增 3 条 + 增补 1 个字段）

### 3.1 `GET /api/folders/roots`

对应 Lody `local-project/list-roots`。鉴权：**Bearer**（免 nonce）。

```jsonc
// 200
{
  "platform": "windows",          // ← 见下方注
  "pathSeparator": "\\",          // JSON 中转义后是 "\\\\"（两个反斜杠字符）
  "homeDir": "C:\\Users\\czk",
  "drives": ["C:\\", "D:\\", "E:\\"]
}
```

> **⚠️ `platform` 取值必须与 Lody 显式区分**
> Lody 用 Node 的 `process.platform`，Windows 上会给出 **`"win32"`**；
> BrewPing 用 Rust 的 `std::env::consts::OS`，Windows 上给出 **`"windows"`**。
> 这里**建议用 `"windows"`**，与 BrewPing 已有的 `DesktopStatus.platform`（`lib.rs:171`）保持一致。
> 好消息：iOS 端 `DeviceOSType.parse`（`ManagedDevice.swift:35-45`）**同时接受
> `"windows"` / `"win"` / `"win32"` / `"win64"`**，所以两端不会打架。
> 但**客户端绝不能硬编码 `win32`** —— 这是本方案中最容易埋下的一处隐性 bug。
> 正确做法：以 `pathSeparator` 与 `drives` 的存在与否驱动 UI，而不靠 `platform` 字符串。

### 3.2 `GET /api/folders`

对应 Lody `local-project/browse-dir`。鉴权：**Bearer**（免 nonce —— 只读）。

| 参数 | 类型 | 缺省 | 说明 |
| --- | --- | --- | --- |
| `path` | `string?` | home | 目标绝对路径；空/缺失回退 home |
| `limit` | `string?` | `200` | clamp 到 `[1, 1000]` |
| `cursor` | `string?` | — | 上一页返回的 `nextCursor`（offset 的字符串形式） |
| `hidden` | `string?` | `false` | `"1"` / `"true"` 视为真，其余为假 |

> **实现约束**：4 个参数在 Rust 侧**必须声明为 `Option<String>` 再手工解析**。
> 若用 `Query<T>` 直接反序列化成 `bool` / `usize`，axum 在解析失败时会返回
> **400 纯文本**，违反仓库既有的 `TC-HT-26`（`http_server.rs:1811-1823`）
> 「**404/错误响应体必须是可解析的 JSON**」契约。详见 §5.5。

```jsonc
// 200
{
  "path": "C:\\Users\\czk\\projects",
  "parentPath": "C:\\Users\\czk",          // C:\ 的 parentPath 必须是 null，见 §5.3
  "entries": [
    { "name": "my-app",     "absolutePath": "C:\\Users\\czk\\projects\\my-app",
      "isSymlink": false, "hidden": false, "hints": { "git": true } },
    { "name": "node_modules","absolutePath": "C:\\Users\\czk\\projects\\node_modules",
      "isSymlink": false, "hidden": false },
    { "name": "locked",     "absolutePath": "C:\\Users\\czk\\projects\\locked",
      "isSymlink": false, "hidden": false, "error": "unreadable" },
    { "name": "link-to-win","absolutePath": "C:\\Windows",
      "isSymlink": true,  "hidden": false }
  ],
  "truncated": false,
  "nextCursor": "200"                      // 仅 truncated 为真时出现
}
```

字段语义（逐条对齐 Lody）：

- `absolutePath` —— **必须是 `dunce::simplified` 之后的路径**（无 `\\?\` 前缀），见 §5.1。
- `isSymlink` —— Windows 上 `is_symlink()` 对 **symlink 与 junction 都返回 `true`**，见 §5.4。
- `hidden` —— 需要扩展到**属性位**，不能只看 dotfile，见 §5.2。
- `hints.git` —— `.git` 存在即真。**注意 `.git` 可能是文件**（worktree / submodule → 内容是 `gitdir: ...`），
  所以判定要用 `exists()` 而**不是 `is_dir()`**。这是 Windows 上容易踩错的一处。
- `error: "unreadable"` —— 目录不可读时**仍然返回该项**，由 UI 置灰不可点。

### 3.3 `POST /api/agents/workdir`

对应 Lody 的 `prepare-add` + 落库，**合并为一步**。鉴权：**Bearer + Timestamp + Nonce**（写操作）。

```jsonc
// 请求
{ "agentId": "claude-code", "path": "C:\\Users\\czk\\projects\\my-app" }
// 清除（回到"不指定"）：                                              
{ "agentId": "claude-code", "path": null }
```

```jsonc
// 200
{ "success": true, "agentId": "claude-code", "workdir": "C:\\Users\\czk\\projects\\my-app" }
// 清除成功
{ "success": true, "agentId": "claude-code", "workdir": null }
```

校验规则（缺一不可）：

1. `agentId` 必须属于 `agent_config::SUPPORTED_AGENTS`（`agent_config.rs:54`），否则 `404 unknown agent`
   —— 与 `handle_agent_models`（`http_server.rs:373-378`）的既有做法一致。
2. `agentId == "opencode"` → `400`，`error: "opencode does not support workdir yet"`（见 §2.3 事实 2）。
3. `path` 非空时：`dunce::canonicalize` 成功、`is_dir()` 为真、**不在 UNC 形态**、**通过根白名单**，
   否则 `400` + 具体错误码（见 §3.5）。校验通过后**存规范化（simplified）路径**。
4. `path` 为 `null` / 空串 → 清除该 Agent 的键（对齐 `model_prefs.set(agent, None)` 语义）。

**幂等性**：重复提交同一路径是**成功且无副作用**的（键值相同），
对应 Lody 的 `status: 'existing'` 语义 —— 但 BrewPing 无需区分，直接返回 `success`。

### 3.4 `GET /api/agents` 增补 `workdir` 字段

**不新增读取端点**。`AgentEntryApi`（`agent_discovery.rs:26-34`）增加一个字段：

```rust
pub struct AgentEntryApi {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub active: bool,
    pub executable: bool,
    pub version: Option<String>,
    pub workdir: Option<String>,   // ★ 新增：null = 未指定（跟随进程当前目录）
}
```

在 `From<&AgentEntry>` 之外，`handle_agents`（`http_server.rs:334-354`）、
`handle_discovery_refresh`（`:869-893`）、`get_status`（`lib.rs:154-161`）、
`get_agents`（`lib.rs:183-190`）**四处**都要把 `workdir_prefs.get(&a.id)` 填进去。

> **顺手修正一处既有漂移**：`src/api/types.ts:26` 写的是 `executable: string | null`，
> 而 Rust 侧序列化出的是 **`bool`**（`agent_discovery.rs:43`，且有测试
> `TC-AD-06`「`executable` 必须是布尔，不能是路径字符串」锁定）。
> 加 `workdir` 时一并把它改成 `executable: boolean`，并跑 `npm run build` 确认 TS 编译通过。

### 3.5 错误码与状态码映射

沿用 BrewPing 既有的 `{ "success": false, "error": "..." }` 形状（**永远是 JSON**）。

| 场景 | HTTP | `error` |
| --- | --- | --- |
| 路径不存在 / 不是目录 / 无法 realpath | `400` | `path-invalid` |
| 路径是 UNC（`\\server\share`） | `400` | `unc-not-allowed` |
| 路径在白名单之外 | `403` | `path-outside-allowlist` |
| 非目录（是文件） | `400` | `path-invalid` |
| 目标无读取权限 | `403` | `permission-denied` |
| `agentId` 不在目录中 | `404` | `unknown agent` |
| `agentId == "opencode"` | `400` | `opencode does not support workdir yet` |
| `limit` / `cursor` 非法 | **降级为缺省值**，不报错（宽容策略，对齐 Lody `clampInteger` / `parseCursor`） |
| 未知路由 | `404` | `no such endpoint: <M> <path>`（既有 `handle_not_found`） |
| 未鉴权 | `401` | `missing bearer token` / `invalid token`（既有 `PairingStore`） |

---

## 4. 逐文件改动点

### 4.1 新增 `src-tauri/src/services/folder_browser.rs`

**约 260 行**（含测试）。职责：目录枚举、根列表、路径规范化、隐藏判定。
**纯逻辑、无 HTTP、无 Tauri 依赖** —— 这是刻意的：HTTP handler 与 Tauri command
都薄薄地调它，保证**只有一份实现**（避免 Lody 早期"两套写入逻辑分叉"的教训）。

对外接口（3 个函数）：

```rust
pub fn list_roots() -> BrowseRoots;
pub fn browse_directory(
    absolute_path: Option<&str>,
    show_hidden: bool,
    limit: Option<usize>,
    cursor: Option<&str>,
) -> Result<BrowseResult, BrowseError>;
pub enum BrowseError { PathInvalid, UncNotAllowed, OutsideAllowlist, PermissionDenied, ExecutionFailed }
```

结构体定义与骨架见 §7.1。

### 4.2 新增 `src-tauri/src/services/workdir_prefs.rs`

**约 150 行**（含测试）。**1:1 照抄 `model_prefs.rs` 的结构**，改三处：

| `model_prefs.rs` | `workdir_prefs.rs` |
| --- | --- |
| `~/.brewping/models.json` | `~/.brewping/workdirs.json` |
| `{"defaultModels": {...}}` | `{"workdirs": {...}}` |
| `struct Stored { #[serde(rename="defaultModels", default)] default_models: HashMap<String,String> }` | `struct Stored { #[serde(rename="workdirs", default)] workdirs: HashMap<String,String> }` |

**必须保留 `#[serde(default)]`**：老用户的 `workdirs.json` 不存在，或存在但缺这个键时，
不能让 decode 失败把整表清空 —— 这是本项目已经踩过并明文记录过的坑
（`ManagedDevice.swift:61-64` 与 `ModelPrefs` 的注释都写了同类教训）。

对外接口：

```rust
pub fn new() -> Self;                                  // 默认路径
pub fn with_path(path: PathBuf) -> Self;                // 测试注入
pub fn get(&self, agent_id: &str) -> Option<String>;
pub fn set(&self, agent_id: &str, workdir: Option<&str>);   // None / "" = 清除
```

**刻意不复用 macOS 的 `config.json`**（与 `model_prefs.rs:8-9` 同样的理由）：
那个文件归 macOS 端所有，BrewPing Windows 只维护自己的一小块，避免两端互相覆盖。

### 4.3 新增 `src-tauri/src/services/folder_api.rs`

**约 120 行**。HTTP handler 层，只做三件事：解析 `Option<String>` 参数、
调 `folder_browser` / `workdir_prefs`、用 `json_response` 组装响应。
把 handler 单独成文件是为了不再膨胀已经 1832 行的 `http_server.rs`。

对外 3 个 `pub` handler：

```rust
pub async fn handle_folder_roots(State(state): State<AppState>) -> Response;
pub async fn handle_browse_folder(State(state): State<AppState>, Query(q): Query<BrowseQuery>) -> Response;
pub async fn handle_set_agent_workdir(State(state): State<AppState>, Json(body): Json<SetWorkdirBody>) -> Response;
```

其中 `handle_browse_folder` **必须**把文件系统调用包进 `tokio::task::spawn_blocking`（见 §5.6）。

### 4.4 改 `src-tauri/src/services/http_server.rs`

共 **4 处**改动：

**(a) `AppState` 增加一个字段**（`:24-40`）：

```rust
pub struct AppState {
    // …既有字段…
    pub workdir_prefs: Arc<WorkdirPrefs>,   // ★ 新增
}
```

> 同步改 `test_state()`（`:1089-1110`）—— 必须用 `WorkdirPrefs::with_path(temp)`，
> 否则单元测试会写到用户真实的 `~/.brewping/workdirs.json`。
> 这与既有 `model_prefs_test_path()`（`:1080-1087`）的隔离做法完全一致。

**(b) `build_router` 增加 3 条路由**（`:241-262`，插在 `/api/agents` 系列附近）：

```rust
.route("/api/folders/roots", get(folder_api::handle_folder_roots))
.route("/api/folders", get(folder_api::handle_browse_folder))
.route("/api/agents/workdir", post(folder_api::handle_set_agent_workdir))
```

**鉴权无需任何改动** —— `route_layer(auth_middleware)`（`:260`）自动覆盖新路由。

**(c) `handle_agents` 填 `workdir`**（`:334-354`）：

```rust
let mut api = AgentEntryApi::from(a);
api.active = api.installed && a.id == default_agent;
api.workdir = state.workdir_prefs.get(&a.id);   // ★ 新增
```

**(d) `submit_command` 注入 cwd**（`:612-614` 取偏好 + `:687-713` 注入）——**本方案的核心改动**：

```rust
// 与 selected_model 同一位置、同一理由：闭包里拿不到 state，必须在 spawn 之前取好。
let selected_model   = state.model_prefs.get(&agent_id);
let selected_workdir = state.workdir_prefs.get(&agent_id);   // ★ 新增
```

闭包内（`:687` 起）：

```rust
let result = tokio::task::spawn_blocking(move || {
    // ★ 先显式校验 cwd —— 位置必须在 Command::new 之前
    if let Some(dir) = workdir_clone.as_deref() {
        if !std::path::Path::new(dir).is_dir() {
            // 目录已被删除 / 改名 / 卸载（U 盘拔掉）。
            // 必须报 invalid_workdir，不能笼统地报 process_exited ——
            // 否则手机端只能看到"进程退出"，无法区分是命令失败还是目录没了。
            let err = format!("Workdir not available: {}", dir);
            { /* append_line(Error) + set_status(Error) */ }
            store_clone.set_failed(&cmd_clone, err,
                Some("invalid_workdir".to_string()), None).await;
            return;
        }
    }

    let mut cmd = std::process::Command::new(&exec_clone);
    cmd.arg(&text_clone);
    if let Some(model) = &model_clone { cmd.arg("--model").arg(model); }
    // ★ 关键一行
    if let Some(dir) = workdir_clone.as_deref() {
        cmd.current_dir(dir);
    }
    cmd.stdout(std::process::Stdio::piped()) /* …既有代码不变… */
})
```

> **为什么不用 `std::env::set_current_dir`**：那是**进程级全局状态**。
> HTTP 服务与 Tauri command 都跑在同一个多线程 runtime 上，
> 全局 `chdir` 会污染其他并发任务（包括同时执行的另一个 Agent）。
> `Command::current_dir` 只影响该子进程，是唯一正确的做法。

同时 `handle_discovery_refresh`（`:869-893`）与 `handle_agent_models` 路径上也要保证
`AgentEntryApi` 的新字段被填充（避免刷新后 `workdir` 变 `null`）。

### 4.5 改 `src-tauri/src/lib.rs`

共 **4 处**：

**(a) `run()` 里构造 `WorkdirPrefs`**（`:594` 附近），并装入 `AppState`（`:596-608`）：

```rust
let model_prefs   = Arc::new(ModelPrefs::new());
let workdir_prefs = Arc::new(WorkdirPrefs::new());   // ★ 新增
```

**(b) `send_command` 注入 cwd**（`:464-529`）—— **与 4.4(d) 完全同构，必须同步改**：

```rust
let workdir_clone = core.state.workdir_prefs.get(&agent_id);   // ★ 在 spawn_blocking 之前取
// …
tokio::task::spawn_blocking(move || {
    if let Some(dir) = workdir_clone.as_deref() {
        if !std::path::Path::new(dir).is_dir() {
            /* append_line(Error) + set_status(Error) + emit("terminal-updated") */
            return;
        }
    }
    let mut cmd = std::process::Command::new(&executable_clone);
    cmd.arg(&text_clone)
       .stdout(std::process::Stdio::piped())
       .stderr(std::process::Stdio::piped());
    if let Some(dir) = workdir_clone.as_deref() {
        cmd.current_dir(dir);     // ★ 关键一行
    }
    /* …既有 PATH 注入与 cmd.output() 不变… */
});
```

> 注意 `lib.rs` 这一侧的失败是**直接写终端**（没有 `CommandStore`），
> 所以只需 `append_line + set_status(Error)` + `emit("terminal-updated")`。

**(c) 可选新增 2 个 Tauri command**（供桌面端 React UI 复用同一份逻辑，
避免它自己走一遍 HTTP 回环）：

```rust
#[tauri::command]
async fn get_folder_roots(core: tauri::State<'_, DesktopCore>) -> Result<serde_json::Value, String>;

#[tauri::command]
async fn browse_folder(
    core: tauri::State<'_, DesktopCore>,
    path: Option<String>, limit: Option<usize>, cursor: Option<String>, hidden: Option<bool>,
) -> Result<serde_json::Value, String>;

#[tauri::command]
async fn set_agent_workdir(
    core: tauri::State<'_, DesktopCore>, agent_id: String, path: Option<String>,
) -> Result<serde_json::Value, String>;
```

并登记进 `invoke_handler`（`:744-762`）。

**(d) 若采纳 (c)**，`get_status` / `get_agents`（`:154-161`、`:183-190`）也要填 `workdir`。

### 4.6 改 `src-tauri/src/services/mod.rs`

```rust
pub mod agent_config;
pub mod agent_discovery;
pub mod approval_gate;
pub mod danger_pattern;
pub mod device_identity;
pub mod folder_api;        // ★ 新增
pub mod folder_browser;    // ★ 新增
pub mod http_server;
pub mod lan_address;
pub mod mdns_broadcast;
pub mod model_prefs;
pub mod pairing_store;
pub mod terminal_state;
pub mod tray;
pub mod workdir_prefs;     // ★ 新增
```

### 4.7 改 `src-tauri/Cargo.toml`

```toml
[dependencies]
# …既有…
dunce = "1.0"                    # ★ 新增：剥离 Windows \\?\ verbatim 前缀
# …既有…

[target.'cfg(windows)'.dependencies]
winreg = "0.55"
windows-sys = { version = "0.52", features = [   # ★ 新增
    "Win32_Foundation",
    "Win32_Storage_FileSystem",
] }
```

- `dunce 1.0.5` 已经在 `Cargo.lock` 里（传递依赖），**显式声明不会引入新下载**，只是让它成为可直接使用的直接依赖。
- `windows-sys 0.52` 同样已在 lock 中。**必须显式列出 feature**，否则
  `GetLogicalDrives` / `GetDriveTypeW` / `GetFileAttributesW` 不可见。
- 若采纳 §4.9 的原生选择器：额外加 `tauri-plugin-dialog = "2"`。

改动后**必须提交更新的 `Cargo.lock`**。

### 4.8 前端类型与调用层（可选，若采纳 §4.5(c)）

| 文件 | 改动 |
| --- | --- |
| `src/api/types.ts` | ① `AgentEntry.executable` 由 `string \| null` **修正为 `boolean`**；② `AgentEntry` 增加 `workdir: string \| null`；③ 新增 `BrowseRoots` / `BrowseEntry` / `BrowseDirectoryResult` 接口 |
| `src/api/tauri.ts` | 新增 `getFolderRoots()` / `browseFolder(path, opts)` / `setAgentWorkdir(agentId, path)` 三个 `invoke` 封装 |
| `src/App.tsx` | 新增 `panel` 取值 `"folders"`（现有 `panel` 是 `"pairing" \| "approval" \| null`，`:58`），加一个浏览弹窗；Agent 行展示当前 `workdir` |
| `src/styles/app.css` | 弹窗与列表样式（沿用既有 `.tabs` / `.agent-tab` 的视觉语言） |

> `App.tsx` 已 508 行且是单文件结构。按本项目既有风格，**建议新增
> `src/components/FolderBrowser.tsx`**，不要把浏览 UI 塞进 `App.tsx`。

### 4.9 桌面端原生目录选择器（可选，需新增权限配置）

**当前仓库没有 `capabilities/` 源码目录**，只有 `gen/schemas/capabilities.json`
这类由 `tauri-build` 自动生成的 schema。`tauri-plugin-dialog` 也不是依赖。

若要在桌面 App 上提供"系统原生文件夹选择对话框"（对标 Lody 侧边栏那条旁路），需要：

1. `Cargo.toml` 加 `tauri-plugin-dialog = "2"`。
2. `lib.rs` 的 `tauri::Builder` 加 `.plugin(tauri_plugin_dialog::init())`。
3. **新建 `src-tauri/capabilities/default.json`**：

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "BrewPing desktop capabilities",
  "windows": ["main"],
  "permissions": ["core:default", "dialog:allow-open"]
}
```

> ⚠️ **这一步是唯一需要新增 Tauri 插件权限面的地方，本项目尚无先例。**
> 现有 `tauri.conf.json` 只写了 `plugins.shell.open = true` 而**没有对应 capability 文件**，
> 说明当前 shell 插件的 `open` 权限是否实际生效**未经核实**。
> 落地前请先确认现有 `tauri_plugin_shell` 的实际工作方式（跑一次 `npm run tauri dev`
> 看是否报 ACL 错误），再决定 capabilities 的写法，**不要照抄本示例**。

**建议：这一步可以延后。** 纯 HTTP 端点方案（§3）已经完全覆盖 iOS 侧需求，
原生对话框只是桌面端锦上添花。

### 4.10 iOS 侧（仅提示，不属本文档范围）

iOS 端需要新增 `FolderBrowserView` + `FolderBrowserStore`（5 态状态机：
`loadingRoots` / `browsing` / `empty` / `permissionDenied` / `failed`），
并消费 §3 的 3 个端点。

两个**必须在 iOS 侧做对**的点：

- **绝不要用 `.fileImporter` / `UIDocumentPickerViewController`** —— 那浏览的是
  iPhone / iCloud 的文件系统，与 Windows 主机毫无关系。必须是**服务端驱动的自绘列表**。
- `BrewPingHTTP.request` 是 `URL(string: base + path)` **字符串拼接**，
  路径含空格 / 中文 / `#`（例如 `C:\Users\czk\我的项目`）会构造失败
  → 必须加 `URLComponents` 版本重载，对 `path` 做 percent-encoding。

详见 `BrewPing-获取文件夹-iOS与macOS落地方案.md`。

### 4.11 可选：mDNS TXT 声明能力

`mdns_broadcast.rs:38-47` 目前广播 6 个 TXT 字段
（`version` / `agent` / `platform` / `protocolVersion` / `deviceId` / `deviceName`）。

可选增加一项，让 iOS 在**配对之前**就知道这台机器支不支持列目录：

```rust
properties.insert("supportsFolderBrowser".to_string(), "1".to_string());
```

好处：iOS 可以对老版本 Windows 端优雅降级（隐藏入口），而不是点了才发现 404。
**代价**：`DeviceOSType.parse` 那类解析器对未知键是宽容的，所以加字段不会破坏兼容。
**建议做，但优先级低。**

---

## 5. Windows 特有技术难点

以下 10 条是**照抄 macOS 那份方案会漏掉**的部分。

### 5.1 `\\?\` verbatim 前缀必须剥离

`std::fs::canonicalize` 在 Windows 上**必定**返回 `\\?\C:\...` 形式（verbatim 路径）。
这是 Win32 的规范行为，不是 bug。后果：

- iOS 显示 `\\?\C:\Users\czk\projects`，用户看不懂
- `Path::join` 在 verbatim 路径上会得到意外结果（verbatim 路径**不做** `.` / `..` 归一化）
- 若把 verbatim 路径回传给前端再拼 `\` 分隔符，容易产生非法路径

**修复**：统一用 `dunce`（1.0.5 已在 lock 中）：

```rust
let real = dunce::canonicalize(&requested)?;                    // 规范化，同时剥前缀
let display = dunce::simplified(&real).to_string_lossy().to_string();
```

**例外**：**>260 字符的超长路径需要 `\\?\` 前缀才能访问**。
建议存盘与传输都用 simplified 形式（可读、与 iOS 一致），
但在交给 `current_dir()` 之前若长度 > 260，用 `dunce::canonicalize` 取回 verbatim 形式。
Rust 标准库在部分路径上会自动处理长路径，但**不要依赖这一点**。

### 5.2 隐藏是**属性位**，不是 dotfile

Windows 的"隐藏"是 `FILE_ATTRIBUTE_HIDDEN`（`0x02`）属性位，与文件名无关。
只判 `name.starts_with('.')` 会漏掉绝大多数 Windows 隐藏目录
（`AppData`、`$RECYCLE.BIN`、`System Volume Information`、用户手动设为隐藏的目录）。

**正确判定**（两者都要认）：

```rust
#[cfg(windows)]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    entry.metadata()
        .map(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
        .unwrap_or(false)
}
// 调用处：
let hidden = name.starts_with('.') || is_hidden(&entry);
```

**为什么用 `DirEntry::metadata()` 而不是 `Path::metadata()`**：
`DirEntry::metadata()` **不跟随 symlink**，且只有**一次**系统调用；
隐藏判定、类型判定、reparse point 判定可以**共用这一次结果**，无需重复 stat。

### 5.3 根是**盘符**，不是 `/`

Linux/macOS 的根是 `/`，Windows 是 `C:\`、`D:\`……（还可能是 `\\server\share`）。

**必须用系统 API 枚举，禁止 A–Z 逐个探测**：

```rust
use windows_sys::Win32::Storage::FileSystem::{
    GetLogicalDrives, GetDriveTypeW, DRIVE_FIXED, DRIVE_REMOTE, DRIVE_REMOVABLE,
};
let mask = unsafe { GetLogicalDrives() };          // 位掩码，bit0 = A:
for i in 0..26u32 {
    if mask & (1 << i) == 0 { continue; }
    let root = format!("{}:\\", (b'A' + i as u8) as char);
    let kind = unsafe { GetDriveTypeW(wide_null(&root).as_ptr()) };
    if matches!(kind, DRIVE_FIXED | DRIVE_REMOVABLE | DRIVE_REMOTE) { /* … */ }
}
```

**为什么不能 A–Z 探测**：空光驱、断开的网络映射盘、已弹出的移动介质，
`Path::exists()` 会产生**数秒级阻塞**（等待设备超时）。26 个盘符轮一遍会让
`/api/folders/roots` 直接卡到超时。`GetDriveTypeW` 是纯内存查询，微秒级。

**另外两条边界**：

- **`C:\` 的 `parentPath` 必须是 `null`**。Windows 上 `Path::new("C:\\").parent()` 返回 `None`，
  天然正确；但要小心 `dunce::simplified("\\\\?\\C:\\D")` 后的行为，加测试锁定。
- **UNC 路径默认拒绝**。`\\server\share` 会触发 SMB 认证（见 §6.2），
  统一返回 `400 unc-not-allowed`。判定：路径以 `\\` 开头且不是 `\\?\` 前缀。

### 5.4 reparse point 的两种语义，必须区别对待

Windows 的 reparse point 家族有两个成员，`std::fs::DirEntry::file_type().is_symlink()`
对它们的行为**不同**，这会造成两个方向相反的坑：

| 类型 | `is_symlink()` | 风险 |
| --- | --- | --- |
| **符号链接**（symlink） | `true` | 需默认创建权限，相对少见 |
| **目录联接 `junction`** | **`true`** | ⚠️ **普通用户即可创建**，是最现实的路径白名单绕过手段 |
| **OneDrive / 云占位文件** | **`false`** | ⚠️ 列目录**不**触发下载，但**读文件内容会** |

**两个直接后果**：

1. **路径白名单必须作用在 realpath 之后**，不能作用在请求路径上。
   一个位于允许根目录内的 junction 指向 `C:\Windows` 时，
   朴素的前缀检查（`path.starts_with(allowed_root)`）会被绕过。
   正确顺序：`dunce::canonicalize(requested)` → **然后**才做白名单比较。
2. **判定 `unreadable` 绝不能读文件内容**。OneDrive 占位文件的 `is_symlink()` 返回 `false`，
   若为了"探测可读性"去 `File::open` 并 `read`，会触发**全量下载用户云盘文件**。
   正确做法：只打开**目录句柄**并立即丢弃：

   ```rust
   fn can_read_dir(path: &Path) -> bool {
       // 只做「能否列出该目录」，绝不读取任何文件内容。
       // DirEntry 迭代器在此立即 drop，不消费任何条目。
       std::fs::read_dir(path).is_ok()
   }
   ```

**附加坑：Windows 8.3 短名**（`PROGRA~1` 指向 `Program Files`，`SECRET~1` 可能指向任意长名目录）
可以绕过基于字符串的白名单比较。**建议直接拒绝名称中含 `~` 的路径**，
或用 `GetLongPathNameW` 取长名后再比较。

### 5.5 `Query` 参数必须 `Option<String>` + 手工解析

axum 的 `Query<T>` 若反序列化失败（`limit=abc`、`hidden=yes`），
返回的是 **400 + `text/plain`**。这会违反仓库既有的契约
`TC-HT-26`（`http_server.rs:1811-1823`）：

> *「未知路由必须返回 JSON 而不是空 body。这是『iPhone 提示无法加载模型列表：格式不正确』的直接病根。」*

**所以全部参数声明为字符串，手工解析，失败时降级为缺省值（而不是报错）**
—— 这也正好对齐 Lody 的 `clampInteger` / `parseLocalProjectBrowseCursor` 宽容策略：

```rust
#[derive(Debug, Deserialize)]
struct BrowseQuery {
    path: Option<String>,
    limit: Option<String>,
    cursor: Option<String>,
    hidden: Option<String>,
}

fn parse_bool_flag(raw: Option<&str>) -> bool {
    matches!(raw.map(str::trim), Some("1") | Some("true") | Some("TRUE") | Some("yes"))
}

fn parse_limit(raw: Option<&str>) -> Option<usize> {
    raw.and_then(|s| s.trim().parse::<usize>().ok())   // 非法 → None → 走缺省
}
```

`handle_browse_folder` 上挂 `Query<BrowseQuery>`，因为每项都是 `Option<String>`，
**任何输入都不会让它解析失败**，从而永远走 JSON 响应路径。

### 5.6 文件系统 I/O 必须 `spawn_blocking`

`read_dir`、`canonicalize`、`metadata` 在**慢盘 / 网络映射盘 / 已断开的移动介质**上
是**阻塞**调用。axum handler 跑在 tokio worker 线程上，直接调用会卡住整个 runtime
（表现为**所有** API 一起变慢，而不只是这一个请求）。

```rust
let result = tokio::task::spawn_blocking(move || {
    folder_browser::browse_directory(path.as_deref(), show_hidden, limit, cursor.as_deref())
}).await;
```

这与 `submit_command`（`http_server.rs:687`）已有做法一致。
**Windows 上这个问题比对 macOS 更严重**，因为网络映射盘（`net use Z: \\nas\share`）
在局域网上非常普遍，而 D 盘可能是断开的映射盘。

### 5.7 路径大小写不敏感

NTFS 默认**大小写不敏感**（`C:\Users` 与 `c:\users` 是同一目录）。
影响两处：

- **白名单比较**：必须做大小写归一化后再比较（`to_ascii_lowercase()`）。
- **去重**：`C:\Users\czk` 与 `C:\users\czk` 是同一个目录。

**但不要用归一化后的路径存盘** —— 会丢失用户原始大小写，显示起来很别扭
（`C:\users\czk\myproject`）。规则：**比较时归一化，存盘时保原样**。

### 5.8 `.git` 可能是文件

`hints.git` 的判定不能用 `is_dir()`：Git worktree 与 submodule 场景下，
`.git` 是一个**普通文件**（内容为 `gitdir: ../.git/modules/xxx`）。用 `exists()` 才对。

### 5.9 `current_dir` 的失败要分类，不能笼统归 `process_exited`

现有失败路径只有两种 `failureReason`：`process_exited`（`http_server.rs:666` / `:752` / `:780`）
与 `None`。cwd 不存在（目录被删 / U 盘拔出 / 网络盘断开）时会表现为
`Command::output()` 返回 `io::Error`，落进 `Ok(Err(e))` 分支（`:767-783`），
被标成 `process_exited` —— **手机端无法区分"命令执行失败"和"工作目录没了"**。

**必须在 spawn 之前显式预检 `Path::is_dir()`**，产出独立的 `invalid_workdir`
（见 §4.4(d) 代码）。`CommandStatusResponse.failureReason`（`http_server.rs:827-828`）
会把它透出到 `GET /api/message/{id}`，因此这是一条**可直接自动化断言**的验收点。

**并且：绝不静默回退到 home 或进程 cwd。** 静默回退意味着 Agent 在
`C:\Windows\System32` 里执行用户命令 —— 那正是本功能要修的那类 bug。

### 5.10 双 spawn 点的一致性是硬约束

§2.3 事实 1 已说明：`http_server.rs:687` 与 `lib.rs:464` 是**两份独立的**
`Command` 构造代码。这不是设计，是历史复制。**本方案不要求重构它们**
（那会扩大改动面与回归风险），但要求：

- 两处**必须同步**加 `.current_dir()` 与预检，**同一批次提交**；
- 两处的错误码与文案必须一致（`invalid_workdir`）；
- 加一条**测试同时覆盖两条路径**（见 §10 的 `TC-WD-07`）。

> 若未来有余力，可把两处合并为一个 `services/agent_runner.rs`，
> 但这**不是本次目标的必要条件**，且会触碰 `send_command` 的事件发射逻辑（`emit("terminal-updated")`），
> 风险大于收益。**建议先不合并。**

---

## 6. 安全边界

### 6.1 本功能新增的是**信息泄露**，不是新的命令执行

必须如实说明量级：BrewPing 的 `/api/message` **本来就允许已配对设备在主机上执行任意命令**
（`ApprovalGate` 只是模式化拦截，`auto` 模式下直接放行，见 `http_server.rs:531`）。
所以本功能新增的能力面是**目录结构泄露**，量级**低于**既有能力。

**唯一真正新增的边界是「根目录白名单」** —— 它防的不是"能不能执行命令"，
而是"能否把你没打算公开的目录树（`C:\Users\其他用户`、公司共享盘）暴露给配对设备"。

### 6.2 必须补的四道措施

| # | 措施 | 理由 |
| --- | --- | --- |
| 1 | **UNC 路径默认拒绝** | ⚠️ **Windows 特有、最严重**：浏览 `\\attacker\share` 会触发 **SMB 认证**，主机名与 NTLM 哈希会被送到攻击者控制的服务器（SMB relay）。这不是"读到不该读的东西"，而是**凭据外泄**。必须在 realpath 之前就按字符串拒绝 `\\` 开头（`\\?\` 前缀除外） |
| 2 | **根目录白名单** | 限制可浏览的根集合（默认 `home` + 用户显式添加的目录）。**必须作用在 realpath 之后**（§5.4 的 junction 绕过）。拒绝跨用户 profile、`C:\Windows`、`C:\ProgramData` |
| 3 | **盘符枚举开关** | `list_roots` 的 `drives` 字段泄露主机磁盘布局。建议加配置 `allowDriveEnumeration`（默认 **true** 以保持本机体验，未来跨机模式下调成 false） |
| 4 | **审计日志** | 每次 `browse_directory` 与 `set_agent_workdir` 记 `log::info!("folder browse: {} -> {}", peer, path)`。写操作尤其要记（`tracing` 已在用 `log` crate）。 |

### 6.3 一条不能做的事

**不要**把 `/api/folders` 实现成通用文件代理（比如支持 `?returnContent=1` 返回文件内容）。
一旦返回内容，就等价于把主机文件系统整个暴露给配对设备，
且会触发 §5.4 的 OneDrive 下载问题。**目录结构可以给，文件内容一律不给。**

### 6.4 令牌模型的既有限制（需知悉，不在本次修复范围）

`PairingStore` 只有**一个**长期 token（`pairing_store.rs:55`），
所有配对设备**共享同一个 token**，没有 per-device 作用域，也没有撤销单个设备的能力
（只能靠 `regenerate_pairing_code` 换码，但已换过 token 的设备不受影响）。

对本功能的影响：**任一配对设备都能浏览目录树，且日志里无法区分是哪一台。**
若要真正的多设备隔离，需要把 token 改成 per-device 存储 ——
那是独立改造，**本方案不包含**，但应在实现时明确记入已知限制。

---

## 7. 代码骨架

### 7.1 `services/folder_browser.rs`

```rust
//! 目录浏览服务（Windows 端）。
//!
//! 对应 Lody `apps/cli/src/lib/local-project-control-service.ts` 的
//! `listBrowseRoots()` / `browseDirectory()`，逐条对齐其 10 步实现。
//!
//! 与 macOS/Linux 的三处关键差异：
//!   1. 根是**盘符**（不能 A–Z 探测，见 list_drives 注释）；
//!   2. 隐藏是 **FILE_ATTRIBUTE_HIDDEN 属性位**，不是 dotfile；
//!   3. realpath 必须剥离 `\\?\` verbatim 前缀（dunce）。

use serde::Serialize;
use std::path::{Path, PathBuf};

/// 单页默认条目数（对齐 Lody DEFAULT_LOCAL_PROJECT_BROWSE_DIR_LIMIT）。
pub const DEFAULT_LIMIT: usize = 200;
/// 单页硬上限（对齐 Lody HARD_LOCAL_PROJECT_BROWSE_DIR_LIMIT）。
pub const HARD_LIMIT: usize = 1000;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseRoots {
    /// 用 std::env::consts::OS → Windows 上是 "windows"。
    /// 注意 Lody 用 Node 的 process.platform → "win32"，两端取值不同，
    /// 客户端不得硬编码（见方案 §3.1）。
    pub platform: &'static str,
    pub path_separator: &'static str,
    pub home_dir: String,
    /// 仅 Windows 有；其它平台为空数组。
    pub drives: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct BrowseHints {
    pub git: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseEntry {
    pub name: String,
    /// 已 realpath 且已剥 `\\?\` 前缀。
    pub absolute_path: String,
    pub is_symlink: bool,
    pub hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hints: Option<BrowseHints>,
    /// 目前只有一种取值："unreadable"。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<&'static str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseResult {
    pub path: String,
    /// `C:\` 的 parent 为 None（Windows 上 Path::parent("C:\\") 即返回 None）。
    pub parent_path: Option<String>,
    pub entries: Vec<BrowseEntry>,
    pub truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowseError {
    PathInvalid,
    UncNotAllowed,
    OutsideAllowlist,
    PermissionDenied,
    ExecutionFailed,
}

impl BrowseError {
    pub fn code(self) -> &'static str {
        match self {
            Self::PathInvalid => "path-invalid",
            Self::UncNotAllowed => "unc-not-allowed",
            Self::OutsideAllowlist => "path-outside-allowlist",
            Self::PermissionDenied => "permission-denied",
            Self::ExecutionFailed => "execution-failed",
        }
    }
    pub fn status(self) -> u16 {
        match self {
            Self::OutsideAllowlist | Self::PermissionDenied => 403,
            Self::UncNotAllowed | Self::PathInvalid => 400,
            Self::ExecutionFailed => 500,
        }
    }
}

// ─── 根列表 ──────────────────────────────────────────────────────────────────

pub fn list_roots() -> BrowseRoots {
    let home = dirs::home_dir()
        .map(|p| simplified(&p))
        .unwrap_or_default();
    BrowseRoots {
        platform: std::env::consts::OS,      // Windows → "windows"
        path_separator: std::path::MAIN_SEPARATOR_STR,
        home_dir: home,
        drives: list_drives(),
    }
}

#[cfg(windows)]
fn list_drives() -> Vec<String> {
    use windows_sys::Win32::Storage::FileSystem::{
        GetDriveTypeW, GetLogicalDrives, DRIVE_FIXED, DRIVE_REMOTE, DRIVE_REMOVABLE,
    };

    // ★ 必须用 GetLogicalDrives 位掩码。禁止 A–Z 逐个 Path::exists() 探测：
    //   空光驱 / 断开的网络映射盘会让 exists() 阻塞数秒，26 次能直接打到超时。
    let mask = unsafe { GetLogicalDrives() };
    let mut out = Vec::new();
    for i in 0..26u32 {
        if mask & (1 << i) == 0 {
            continue;
        }
        let root = format!("{}:\\", (b'A' + i as u8) as char);
        let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
        let kind = unsafe { GetDriveTypeW(wide.as_ptr()) };
        if matches!(kind, DRIVE_FIXED | DRIVE_REMOVABLE | DRIVE_REMOTE) {
            out.push(root);
        }
    }
    out
}

#[cfg(not(windows))]
fn list_drives() -> Vec<String> {
    Vec::new()
}

// ─── 目录浏览 ────────────────────────────────────────────────────────────────

pub fn browse_directory(
    absolute_path: Option<&str>,
    show_hidden: bool,
    limit: Option<usize>,
    cursor: Option<&str>,
) -> Result<BrowseResult, BrowseError> {
    // 步骤 1：缺省回退 home。Lody: resolveLocalProjectBrowsePath()
    let requested: PathBuf = match absolute_path.map(str::trim) {
        Some(p) if !p.is_empty() => PathBuf::from(p),
        _ => dirs::home_dir().ok_or(BrowseError::PathInvalid)?,
    };

    // 步骤 1.5（Windows 特有）：UNC 必须在 realpath **之前**拒绝。
    //   \\attacker\share 会触发 SMB 认证 → 主机名与 NTLM 哈希外泄。
    //   注意 \\?\ 是合法的 verbatim 前缀，不算 UNC。
    let raw = requested.to_string_lossy();
    if raw.starts_with("\\\\") && !raw.starts_with("\\\\?\\") {
        return Err(BrowseError::UncNotAllowed);
    }

    // 步骤 2：realpath + 目录校验。dunce 会剥离 \\?\ 前缀。
    let real = dunce::canonicalize(&requested).map_err(|_| BrowseError::PathInvalid)?;
    let meta = std::fs::metadata(&real).map_err(|_| BrowseError::PathInvalid)?;
    if !meta.is_dir() {
        return Err(BrowseError::PathInvalid);
    }

    // 步骤 2.5：白名单必须作用在 realpath 之后 ——
    //   允许根目录内的 junction 可指向任意位置，朴素前缀检查会被绕过。
    if !crate::services::folder_browser::is_within_allowlist(&real) {
        return Err(BrowseError::OutsideAllowlist);
    }

    // 步骤 3：limit clamp + offset。宽容策略：非法值降级为缺省，不报错。
    //   Lody: clampInteger() / parseLocalProjectBrowseCursor()
    let limit = limit.unwrap_or(DEFAULT_LIMIT).clamp(1, HARD_LIMIT);
    let offset: usize = cursor.and_then(|c| c.trim().parse().ok()).unwrap_or(0);

    // 步骤 5：readdir
    let reader = std::fs::read_dir(&real).map_err(|e| {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            BrowseError::PermissionDenied
        } else {
            BrowseError::ExecutionFailed
        }
    })?;

    let mut candidates: Vec<(String, PathBuf, bool)> = Vec::new(); // (name, realpath, is_symlink)

    for entry in reader {
        let Ok(entry) = entry else { continue };
        let name = entry.file_name().to_string_lossy().to_string();

        // 步骤 6a：跳过空 / . / ..
        if name.is_empty() || name == "." || name == ".." {
            continue;
        }

        // 步骤 6b：隐藏 = dotfile ∨ FILE_ATTRIBUTE_HIDDEN（两者都要认）。
        //   只判 dotfile 会漏掉 AppData、$RECYCLE.BIN 等绝大多数 Windows 隐藏目录。
        let hidden = name.starts_with('.') || is_hidden(&entry);
        if hidden && !show_hidden {
            continue;
        }

        // DirEntry::metadata() 不跟随 symlink，且无需额外系统调用。
        let Ok(md) = entry.metadata() else { continue };
        let is_link = md.file_type().is_symlink();

        // 步骤 6c：软链/junction 按 realpath 判定，失败（悬空链）静默跳过。
        let target = if is_link {
            match dunce::canonicalize(entry.path()) {
                Ok(p) => p,
                Err(_) => continue,
            }
        } else {
            entry.path()
        };

        // 步骤 6d：realpath 后不是目录 → 跳过（文件被过滤，空目录保留）。
        let Ok(tmd) = std::fs::metadata(&target) else { continue };
        if !tmd.is_dir() {
            continue;
        }

        candidates.push((name, target, is_link));
    }

    // 步骤 7：稳定排序（Windows 大小写不敏感，用不敏感比较更符合资源管理器直觉）。
    candidates.sort_by(|l, r| l.0.to_lowercase().cmp(&r.0.to_lowercase()));

    // 步骤 8：分页
    let total = candidates.len();
    let start = offset.min(total);
    let end = (offset + limit).min(total);
    let page = &candidates[start..end];

    // 步骤 9：逐项组装
    let entries: Vec<BrowseEntry> = page
        .iter()
        .map(|(name, path, is_link)| {
            let absolute = simplified(path);
            BrowseEntry {
                name: name.clone(),
                absolute_path: absolute.clone(),
                is_symlink: *is_link,
                hidden: name.starts_with('.') || path_is_hidden(path),
                // .git 可能是**文件**（worktree / submodule），所以用 exists() 而非 is_dir()。
                hints: Some(BrowseHints {
                    git: Path::new(&absolute).join(".git").exists(),
                }),
                // ★ 只探测"能否列出该目录"，绝不读取文件内容 ——
                //   OneDrive 占位文件一旦被读就触发全量下载。
                error: if can_read_dir(path) { None } else { Some("unreadable") },
            }
        })
        .collect();

    // 步骤 10：游标就是 offset 的字符串形式，服务端无状态。
    let truncated = end < total;
    Ok(BrowseResult {
        path: simplified(&real),
        parent_path: parent_of(&real),
        entries,
        truncated,
        next_cursor: if truncated { Some(end.to_string()) } else { None },
    })
}

/// 剥掉 Windows 的 `\\?\` verbatim 前缀，得到可展示、可回传前端的路径。
/// 非 Windows 平台上是恒等变换。
fn simplified(path: &Path) -> String {
    dunce::simplified(path).to_string_lossy().to_string()
}

/// `C:\` 的父目录必须是 `None`（Windows 上 Path::parent 天然如此，此处加显式保护）。
fn parent_of(dir: &Path) -> Option<String> {
    let parent = dir.parent()?;
    // 防御：某些输入下 parent 可能等于自身或退化成 drive-relative（"C:"），统一丢弃。
    if parent.as_os_str().is_empty() || parent == dir {
        return None;
    }
    let s = simplified(parent);
    // "C:" 这种无根形式对前端无意义，视为无父目录。
    if s.len() == 2 && s.ends_with(':') {
        return None;
    }
    Some(s)
}

#[cfg(windows)]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    entry
        .metadata()
        .map(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
        .unwrap_or(false)
}

#[cfg(not(windows))]
fn is_hidden(_entry: &std::fs::DirEntry) -> bool {
    false
}

/// 已在候选列表中的路径，用属性位判隐藏（避免二次 stat 失败时误判）。
fn path_is_hidden(path: &Path) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        return std::fs::metadata(path)
            .map(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
            .unwrap_or(false);
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        false
    }
}

/// 只探测能否列出目录，**绝不读取任何文件内容**。
fn can_read_dir(path: &Path) -> bool {
    std::fs::read_dir(path).is_ok()
}

/// 白名单判定：**必须**在 realpath 之后调用，且大小写归一化。
pub fn is_within_allowlist(real: &Path) -> bool {
    let Some(roots) = allowlist_roots() else {
        return true; // 未配置白名单 = 不限制（保持本机体验；跨机部署时应收紧）
    };
    let target = real.to_string_lossy().to_ascii_lowercase();
    roots.iter().any(|root| {
        let root = root.to_string_lossy().to_ascii_lowercase();
        target == root.trim_end_matches('\\') || target.starts_with(&format!("{}\\", root.trim_end_matches('\\')))
    })
}

/// 白名单根集合。默认：home + 全部固定盘符（可在后续版本改为配置项 / 由 UI 管理）。
fn allowlist_roots() -> Option<Vec<PathBuf>> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        roots.push(home);
    }
    for drive in list_drives() {
        roots.push(PathBuf::from(drive));
    }
    if roots.is_empty() { None } else { Some(roots) }
}
```

**对应测试**（沿用仓库的 `TC-xx-NN` 命名习惯）：

| ID | 断言 |
| --- | --- |
| `TC-FB-01` | `list_roots()` 的 `path_separator` 在 Windows 上是 `"\\"`；`platform` 是 `"windows"`（**显式锁定，防止有人改成 `win32`**） |
| `TC-FB-02` | `list_drives()` 返回的每项都以 `:\` 结尾，且无重复 |
| `TC-FB-03` | `browse_directory(None, ...)` 回退到 home |
| `TC-FB-04` | 对文件路径调用 → `Err(PathInvalid)` |
| `TC-FB-05` | 对不存在的路径 → `Err(PathInvalid)` |
| `TC-FB-06` | UNC 路径 `\\server\share` → `Err(UncNotAllowed)`；`\\?\C:\` **不应**被判为 UNC |
| `TC-FB-07` | `canonicalize` 结果已剥 `\\?\`（断言 `absolute_path` 不以 `\\\\?\\` 开头） |
| `TC-FB-08` | 属性位隐藏目录在 `show_hidden=false` 时不出现、`true` 时出现 |
| `TC-FB-09` | dotfile（`.git`）在 `show_hidden=false` 时不出现 |
| `TC-FB-10` | 文件被过滤，空目录保留 |
| `TC-FB-11` | `limit` 与 `cursor` 协作：取两页可覆盖全部条目且无重复（`nextCursor` = offset 字符串） |
| `TC-FB-12` | 目录为空时 `entries: []`, `truncated: false`, 无 `nextCursor` |
| `TC-FB-13` | 含 `.git` **目录**的条目 `hints.git == true` |
| `TC-FB-14` | 含 `.git` **文件**（worktree 形态）的条目 `hints.git == true` |
| `TC-FB-15` | `C:\` 的 `parent_path` 为 `None` |
| `TC-FB-16` | 白名单外的路径 → `Err(OutsideAllowlist)`（配 `allowlist_roots` 的测试注入） |
| `TC-FB-17` | 序列化字段名是 camelCase（`absolutePath` / `isSymlink` / `parentPath` / `nextCursor`），与 iOS 契约一致 |
| `TC-FB-18` | `BrowseError::code()` / `status()` 映射正确 |

### 7.2 `services/workdir_prefs.rs`

与 `model_prefs.rs` 同构，改三处命名即可（见 §4.2）。

| ID | 断言 |
| --- | --- |
| `TC-WP-01` | `set` 后落盘，`with_path` 重新加载仍读到 |
| `TC-WP-02` | 各 Agent 互不影响；`None` / `""` 等于清除 |
| `TC-WP-03` | 文件损坏 / 不存在时退化为空表，不 panic |
| `TC-WP-04` | **旧文件缺少 `workdirs` 键时不得清空已有内容**（`#[serde(default)]` 的回归保护） |

### 7.3 `submit_command` 的 cwd 注入（改 `http_server.rs`）

见 §4.4(d)。**测试在下一节。**

---

## 8. 验证方式

### 8.1 Rust 单元 / 集成测试

本项目已有完整范式：`http_server.rs:1034-1832` 的内嵌 `mod tests` 用**裸 TCP 客户端**
（`request_authorized`，`:1141-1188`）直接打真实服务端，并用
`TEST_TOKEN`（`:1050`）+ `PairingStore::with_fixed_token` 注入可预期 token。
新增的 HTTP 端点测试**直接复用这套设施**，无需新依赖。

### 8.2 手动验证（跨机 / 局域网）

```bash
# 1. 在 Windows 主机上揭示配对码（托盘菜单或桌面 UI），
#    用 iPhone 配对换取 token，或直接从 ~/.brewping/pairing.json 读 token：
#    { "token": "<64位hex>", "createdAt": "..." }

# 2. 在局域网另一台机器上验证（注意 Windows 路径 JSON 双反斜杠转义）
TOKEN=<64位hex>
HOST=192.168.x.x:8787

# 根列表
curl -s -H "Authorization: Bearer $TOKEN" "http://$HOST/api/folders/roots"

# 浏览 home
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST/api/folders" | jq '.path, .entries[0:3]'

# 浏览指定目录（路径里的反斜杠在 JSON/URL 中需转义）
curl -s -H "Authorization: Bearer $TOKEN" \
  --get --data-urlencode 'path=C:\Users\czk' \
  "http://$HOST/api/folders"

# 分页
curl -s -H "Authorization: Bearer $TOKEN" \
  --get --data-urlencode 'path=C:\' --data 'limit=10' \
  "http://$HOST/api/folders"

# 设工作目录（写操作 —— 必须带 timestamp + nonce）
TS=$(date +%s); NONCE=$(uuidgen)
curl -s -X POST "http://$HOST/api/agents/workdir" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-BrewPing-Timestamp: $TS" \
  -H "X-BrewPing-Nonce: $NONCE" \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"claude-code","path":"C:\\Users\\czk\\projects\\my-app"}'

# 回读（workdir 应该出现在 agents 列表里）
curl -s -H "Authorization: Bearer $TOKEN" "http://$HOST/api/agents" | jq '.agents[] | {id, workdir}'
```

> PowerShell 下 `curl` 是 `Invoke-WebRequest` 的别名，请显式用 `curl.exe`
> 或 `Invoke-RestMethod`，否则参数语义不同。

### 8.3 **验证 cwd 真正生效**（本方案最难验的一环）

⚠️ **Windows 没有 `lsof` 等价物**：`wmic process get` 与 `Get-Process` 只能给出
**可执行文件路径**，**查不到进程的当前工作目录**（用户态没有查询 API，
cwd 存在于目标进程的 PEB 中）。所以不能照抄 macOS 那份方案的验证方法。

三条可用手段，从确定到间接：

**(1) 机制层单元测试（确定性，可自动化）** —— 验证「`Command::current_dir` 在 Windows 上确实切目录」：

```rust
#[test]
fn current_dir_switches_subprocess_cwd() {
    let dir = std::env::temp_dir().join(format!("brewping-cwd-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let out = std::process::Command::new("cmd")
        .args(["/c", "cd"])
        .current_dir(&dir)
        .output()
        .expect("cmd 应能启动");

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(
        stdout.trim().to_ascii_lowercase(),
        dir.to_string_lossy().trim().to_ascii_lowercase(),
        "子进程 cwd 未切到指定目录"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
```

> 这只是验证**机制**，不验证我们的**接线**。所以还需要 (2) 或 (3)。

**(2) 接线层集成测试（确定性，可自动化）** —— 这是**最推荐**的一条：
利用 §5.9 新增的 `invalid_workdir` 错误码作为**可观测探针**：

```
1. POST /api/agents/workdir {agentId:"claude-code", path:"<存在的目录>"}  → 200
2. 把该目录删掉（或改名）
3. POST /api/session/start（默认 agent 切到 claude-code）
4. POST /api/message {"text":"x"}
5. 轮询 GET /api/message/{id}
   → 断言 status == "failed" 且 failureReason == "invalid_workdir"
```

这一步**同时**证明了三件事：偏好被读到、预检生效、错误分类正确。
且完全不需要外部工具。

**(3) 人工确认（唯一能直接看到 cwd 的方式）**：
用 **Sysinternals Process Explorer** —— 双击目标进程 → `Properties` → `Image` 标签 →
`Current Directory` 字段。这是用户态下读取目标 PEB 的实用手段。
（`wmic` / `Get-Process` / `Get-CimInstance Win32_Process` **都做不到**，不要浪费时间去试。）

### 8.4 边界与负向验证清单

| 场景 | 期望 |
| --- | --- |
| `path=C:\Windows\System32`（白名单内，但非用户目录） | 能列（属正常能力，非缺陷） |
| `path=\\attacker\share` | `400 unc-not-allowed`（**且不应产生任何 SMB 网络流量**） |
| `path=C:\Users\czk\..\..\Windows` | 经 realpath 后落在白名单内 → 能列（`..` 被规范化，不是绕过） |
| `path` 指向 junction → 白名单外 | `403 path-outside-allowlist`（**验证白名单作用在 realpath 之后**） |
| `path` 指向 OneDrive 占位目录 | 能列，**且网络抓包确认未触发文件下载** |
| `limit=abc` / `hidden=yes` | `200` + 缺省值（**不是 400 纯文本**，护住 `TC-HT-26`） |
| 未鉴权访问 `/api/folders` | `401` + **JSON** body |
| `POST /api/agents/workdir` 无 nonce | `401 missing timestamp/nonce` |
| 设 workdir 后删除该目录，再发消息 | `failureReason == "invalid_workdir"` |
| `POST` 设 `opencode` 的 workdir | `400`，明确说明不支持 |

---

## 9. 分阶段实施清单

### 阶段 1 —— 数据层与浏览逻辑（无 HTTP，可独立测试）

- [ ] `Cargo.toml`：补 `dunce = "1.0"` 与 `windows-sys 0.52`（含两个 feature）
- [ ] 新增 `services/workdir_prefs.rs`（照抄 `model_prefs.rs`，改 3 处命名）
- [ ] 新增 `services/folder_browser.rs`（`list_roots` / `browse_directory` / `list_drives` /
      `is_hidden` / `can_read_dir` / `is_within_allowlist` / `simplified` / `parent_of`）
- [ ] `services/mod.rs` 登记两个新模块
- [ ] 跑通 §7.1 + §7.2 全部单元测试（`TC-FB-01..18`、`TC-WP-01..04`）
- **验收**：`cargo test` 全绿；`cargo clippy` 无新增告警

### 阶段 2 —— HTTP 端点

- [ ] 新增 `services/folder_api.rs`（3 个 handler，参数一律 `Option<String>`）
- [ ] `AppState` 增 `workdir_prefs`；同步改 `test_state()` 用临时路径隔离
- [ ] `build_router` 增 3 条路由
- [ ] `AgentEntryApi` 增 `workdir`；`handle_agents` / `handle_discovery_refresh` 填充
- [ ] 跑通 §10 的 `TC-HT-28..36`
- **验收**：`curl` 能在局域网另一台机器上打通 3 个端点

### 阶段 3 —— cwd 注入（**本方案的核心，两处必须同批提交**）

- [ ] `http_server.rs`：`submit_command` 取 `selected_workdir`（spawn 之前）→
      闭包内预检 + `cmd.current_dir()`
- [ ] `lib.rs`：`send_command` 同构改动
- [ ] 引入 `invalid_workdir` 失败码
- [ ] `lib.rs` 构造并注入 `WorkdirPrefs`；`get_status` / `get_agents` 填 `workdir`
- [ ] 跑通 §10 的 `TC-WD-01..08`，含 §8.3(2) 的接线层集成测试
- **验收**：Process Explorer 看到子进程 `Current Directory` 变了；
      删除目录后 `failureReason == "invalid_workdir"`

### 阶段 4 —— 桌面端 UI（可选）

- [ ] 修正 `types.ts` 的 `executable` 类型漂移 + 增 `workdir` + 3 个浏览类型
- [ ] `tauri.ts` 增 3 个 `invoke` 封装
- [ ] 新增 `components/FolderBrowser.tsx`（**不要塞进 `App.tsx`**）
- [ ] `App.tsx` 增 `panel: "folders"`；Agent 行展示 workdir
- [ ] 可选：mDNS TXT 增 `supportsFolderBrowser`
- [ ] 可选（延后）：`tauri-plugin-dialog` + `capabilities/default.json`
- **验收**：`npm run build` 通过；桌面端能浏览并设置

### 阶段 5 —— 与 iOS 联调

- [ ] 交接口径（§3 契约 + §3.1 的 `platform` 取值警示）
- [ ] 验证 `URLComponents` 重载对中文/空格路径有效
- [ ] 跑通 §10 的端到端用例

---

## 10. 验收用例

### 10.1 新增 HTTP 契约用例（延续既有 `TC-HT` 编号，紧接 `TC-HT-27`）

| ID | 用例 | 断言 |
| --- | --- | --- |
| `TC-HT-28` | `GET /api/folders/roots` 契约 | `200`；含 `platform` / `pathSeparator` / `homeDir` / `drives` 四个键；`drives` 是数组 |
| `TC-HT-29` | **`platform` 取值锁定** | 等于 `"windows"`（**显式断言，防止被改成 `win32` 而与 `DesktopStatus.platform` 不一致**） |
| `TC-HT-30` | `GET /api/folders` 默认回退 home | `200`；`path` 与 `homeDir` 一致（忽略大小写） |
| `TC-HT-31` | 非法 `limit` / `hidden` 不得返回 400 纯文本 | 传 `limit=abc&hidden=yes` → `200`，body 可被 `serde_json::from_str` 解析（护住 `TC-HT-26`） |
| `TC-HT-32` | UNC 路径拒绝 | `path=\\server\share` → `400`，`error == "unc-not-allowed"` |
| `TC-HT-33` | 白名单外路径拒绝 | 注入白名单外的路径 → `403`，`error == "path-outside-allowlist"` |
| `TC-HT-34` | `POST /api/agents/workdir` 成功并可回读 | `200` + `workdir` 非空；随后 `GET /api/agents` 里该 agent 的 `workdir` 一致 |
| `TC-HT-35` | `opencode` 明确拒绝 | `agentId=opencode` → `400`，`error` 含 `"does not support workdir"` |
| `TC-HT-36` | 未知 agent → 404 JSON | `agentId=no-such-agent` → `404` + `success:false` + `error` 是字符串 |
| `TC-HT-37` | 新端点受鉴权保护 | `/api/folders/roots`、`/api/folders`、`/api/agents/workdir` 匿名访问 → `401` + JSON |
| `TC-HT-38` | 写端点要求 nonce | `POST /api/agents/workdir` 只带 Bearer → `401 missing timestamp/nonce` |
| `TC-HT-39` | 目录浏览不泄露文件内容 | 响应体内**不含**任何文件正文；`entries` 里只有目录项 |

### 10.2 cwd 注入用例

| ID | 用例 | 断言 |
| --- | --- | --- |
| `TC-WD-01` | `workdir_prefs` 未设置时不改变既有行为 | `get()` 返回 `None`；`submit_command` 不调用 `current_dir`（进程 cwd 不变） |
| `TC-WD-02` | 设置后子进程 cwd 生效（`cmd /c cd`） | stdout 等于设定目录（大小写不敏感比较） |
| `TC-WD-03` | **两条执行路径一致** | 通过 HTTP（`submit_command`）与通过 Tauri（`send_command`）设同一 workdir，子进程 cwd 相同 |
| `TC-WD-04` | 目录不存在 → `invalid_workdir` | `failureReason == "invalid_workdir"`（**不是** `process_exited`） |
| `TC-WD-05` | 清除 workdir 后回到默认 | `set(agent, None)` 后 `get()` 为 `None` |
| `TC-WD-06` | 多 Agent 隔离 | 给 `claude-code` 与 `codex` 设不同目录，各自子进程 cwd 互不影响 |
| `TC-WD-07` | 并发不串目录 | 两个 Agent 并发执行，各自 cwd 正确（**验证未使用进程级 `set_current_dir`**） |
| `TC-WD-08` | 超长路径（>260 字符） | 仍能设为 workdir 并成功执行 |

### 10.3 端到端（iOS ↔ Windows）

| ID | 用例 |
| --- | --- |
| `E2E-01` | iPhone 打开浏览页 → 列出盘符与 home → 进入某目录 → 点「设为工作目录」→ 主机 `/api/agents` 反映新值 |
| `E2E-02` | 浏览含 300+ 子目录的目录 → 首屏 200 条 + 「加载更多」→ 第二页无重复无遗漏 |
| `E2E-03` | 路径含中文/空格（`C:\Users\czk\我的 项目`）→ 能浏览、能设置（验证 iOS 的 `URLComponents` 重载） |
| `E2E-04` | 目标目录不可读 → iPhone 显示置灰项 + Lock 图标，**不是**"这个文件夹是空的" |
| `E2E-05` | 未配对设备访问 → `401`，iPhone 提示需要配对 |
| `E2E-06` | 老版本 Windows 端（无这些端点）→ iPhone 收到 `404` **JSON** 并能优雅降级（护住 `TC-HT-26` 的跨端价值） |
| `E2E-07` | 设 workdir 后，Agent 的产出（如 `/api/status` 的 `project`，若已有该字段）反映新目录名 |

---

## 11. 约束与非目标

### 11.1 明确不在本次范围

| 项 | 原因 |
| --- | --- |
| **`opencode` 的 workdir 生效** | 它是 stub，需要先做 ConPTY（`CreatePseudoConsole`）—— 独立工程 |
| 把两处 `Command` 构造重构为单一 `agent_runner.rs` | 会触碰事件发射逻辑，风险 > 收益（§5.10） |
| 多设备 / per-device token 作用域 | `PairingStore` 单 token 模型，属独立改造（§6.4） |
| 文件内容读取（下载/预览） | 重大安全面扩张，且触发 OneDrive 下载（§6.3） |
| 跨用户 profile / 系统目录的显式授权管理 UI | 可后续版本迭代 |
| macOS 端同步实现 | 见另一份方案文档 |

### 11.2 需要注意的实现约束

- **`#[serde(default)]` 不可省**（`workdir_prefs::Stored`），否则老用户配置文件会让 decode 失败（`TC-WP-04`）。
- **两处 spawn 同批提交**，否则出现"手机端生效、桌面端不生效"的分裂（§5.10）。
- **`pathSeparator` 在 JSON 里是 `"\\"`**（两个反斜杠字符）。前端解析后才是单个 `\`。这是最常见的接线错误来源。
- **游标是 offset 字符串**，不是不透明 token。前端不要尝试解析其含义，只做回传。
- **`limit` 的 clamp 边界是 `[1, 1000]`**，`0` 与 `100000` 都要被夹住，而非报错。
- **排序用大小写不敏感**更接近 Windows 资源管理器直觉，但与 Lody 的 `localeCompare` 不完全一致 —— 这是**有意的偏离**，因为 Windows 文件系统本身大小写不敏感。
- **不要用 `std::env::set_current_dir`**（§4.4(d) 已说明理由）。
- **新增失败码 `invalid_workdir` 后**，iOS 侧若对 `failureReason` 做穷举匹配，需要同步加分支；若只做兜底展示则无需改动。

---

## 12. 关键文件索引

### Windows 端（路径前缀 `Sources/BrewPingwinDesktop/`）

| 文件 | 行 | 本方案涉及 |
| --- | --- | --- |
| `src-tauri/src/services/http_server.rs` | 1832 | `:24-40` `AppState`；`:224-237` `auth_middleware`；`:241-262` `build_router`；`:334-354` `handle_agents`；`:576-810` `submit_command`；**`:687-713` spawn 点 ①**；`:620-639` opencode stub；`:812-834` `CommandStatusResponse`；`:869-893` `handle_discovery_refresh`；`:1034-1832` 测试设施；`:1811-1823` `TC-HT-26` |
| `src-tauri/src/lib.rs` | 804 | `:39-49` `DesktopCore`；`:154-161` `get_status`；`:183-190` `get_agents`；`:382-416` opencode stub；**`:464-529` spawn 点 ②**；`:596-608` `AppState` 构造；`:744-762` `invoke_handler` |
| `src-tauri/src/services/agent_discovery.rs` | 332 | `:26-47` `AgentEntryApi`（增 `workdir`）；`:43` `executable` 是 bool；`:287-331` `TC-AD-06` |
| `src-tauri/src/services/model_prefs.rs` | 154 | ★ `workdir_prefs.rs` 的模板 |
| `src-tauri/src/services/agent_config.rs` | 513 | `:54` `SUPPORTED_AGENTS`；`:57-59` `is_known_agent`；`:63-64` "坏配置退化为空"范式 |
| `src-tauri/src/services/pairing_store.rs` | 602 | `:170-248` `authorize`；`:193-195` **GET 免 nonce** |
| `src-tauri/src/services/terminal_state.rs` | 215 | `:35-45` `AgentTerminalState` |
| `src-tauri/src/services/mdns_broadcast.rs` | 102 | `:38-47` TXT 字段（可选扩展） |
| `src-tauri/src/services/mod.rs` | 12 | 模块登记 |
| `src-tauri/Cargo.toml` | 37 | 增 `dunce` + `windows-sys` |
| `src-tauri/tauri.conf.json` | 46 | 可选：capabilities |
| `src/api/types.ts` | 91 | `:21-28` `AgentEntry`；`:26` **`executable` 类型漂移** |
| `src/api/tauri.ts` | 138 | 增 3 个 `invoke` 封装 |
| `src/App.tsx` | 508 | `:58` `panel` 状态；新增浏览入口 |
| `src/styles/app.css` | 676 | 弹窗样式 |

### 跨项目参考

| 文件 | 用途 |
| --- | --- |
| `.workbuddy/outputs/Lody-本地项目添加-本地与局域网规格.md` | ★ 对标源：§6.5 `browseDirectory` 10 步、§3.4 协议、§8.3 本地平面、§8.5 安全措施、§9.3 边界 |
| `.workbuddy/outputs/BrewPing-获取文件夹-iOS与macOS落地方案.md` | iOS 端落地（若已被清理，可从 §4.10 的要点重建） |
| `D:\study\lody\Lody\Lody\apps\cli\src\lib\local-project-control-service.ts:1347 / :1358` | Lody 原始实现 |
| `ios/BrewPing/ManagedDevice.swift:35-45` | `DeviceOSType.parse` —— 证明 `windows` / `win32` 都被接受 |
| `ios/BrewPing/BrewPingHTTP.swift` | iOS 请求封装（`URLComponents` 重载的落点） |
| `ios/BrewPing/DemoBackend.swift:82-190` | Demo 路由 switch —— 新增端点时**必须同步**，否则 Demo 模式 404 |
| `docs/AppStore-PreSubmission-Review.md` | iOS 合规（本方案不新增 iOS 权限，无需改） |

---

## 附录 A：与 macOS 方案的差异速查

| 维度 | macOS 端 | Windows 端 |
| --- | --- | --- |
| HTTP 框架 | 自研 `HTTPServer.parseHead` | **axum 0.8** |
| query string | ⚠️ **被整段丢弃**（`HTTPServer.swift:203-206`，`HTTPRequest` 无 query 字段）→ 需先补约 25 行解析层 | ✅ 原生支持，只需 1 个 `Query<BrowseQuery>` |
| 目录读取方 | `Sources/App/FolderBrowserService.swift`（新增） | `services/folder_browser.rs`（新增） |
| 权限模型 | ⚠️ TCC：`~/Desktop` / `~/Documents` / `~/Downloads` / 外置卷受保护，**弹窗出现在 Mac 而按钮在手机上点** | ✅ 无 TCC；改由 ACL 决定，`read_dir` 失败即 `unreadable` |
| `swift run` 归因问题 | ⚠️ 从终端启动时 TCC 归因给终端 App，出现"我的机器能浏览、打包后不行" | ✅ 无此问题 |
| 路径根 | `/` | **盘符**（`GetLogicalDrives`） |
| 隐藏判定 | `name.starts_with('.')` 即可 | **必须是 dotfile ∨ `FILE_ATTRIBUTE_HIDDEN`** |
| realpath | 直接可用 | **必须剥 `\\?\`**（`dunce`） |
| 软链 | symlink | **symlink 与 junction 都是 `is_symlink()==true`**；OneDrive 占位是 `false` 但读内容会下载 |
| 子进程 cwd | ⚠️ `execv` 前无 `chdir`（`PTYSession.swift:86-93`）→ 补 `chdir` | ⚠️ `Command::new` 无 `.current_dir()`（**两处**）→ 补 `current_dir` |
| cwd 验证手段 | `lsof -p <pid>` | ⚠️ **无等价物**；用 `invalid_workdir` 探针 + Process Explorer |
| 构建/测试 | 需 Xcode（Windows 上无法编译验证） | ✅ 本机 `cargo test` + `npm run build` 全可跑 |

## 附录 B：给实现者的三句话

1. **唯一"不做就白干"的点是 `Command::current_dir()`，且必须改两处**
   （`http_server.rs:687` 与 `lib.rs:464`）—— 漏了不会报错，只会静默跑在错误的目录里。
2. **Windows 的四个独有坑按这个优先级处理**：UNC 拒绝（安全问题，最严重）→
   `\\?\` 剥离（影响可用性）→ 隐藏属性位（影响完整性）→ 盘符枚举方式（影响性能）。
3. **`opencode` 是 stub 这一点必须如实告诉用户** —— 设了 workdir 也不会生效，
   不要让它表现为"功能时好时坏"。
