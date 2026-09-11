import Foundation

/// 授权模式：决定 agent 发起/执行的操作在多大程度上需要用户确认。
///
/// - `.safe`（默认）：只拦截命中危险模式的操作，其余自动放行。
/// - `.askAll`：每一条命令都要确认（供极度谨慎的用户手动升级）。
/// - `.auto`：全程免确认，等同 Claude Code 的 `--dangerously-skip-permissions`。
///
/// 默认落在 `.safe`，是「默认谨慎 + 渐进放权」策略的锚点：
/// 首装用户对"手机遥控 Mac 执行命令"的风险尚未建立认知，必须从最安全一档起步。
enum ApprovalMode: String, Codable, CaseIterable {
    case safe
    case askAll = "askAll"
    case auto
}

/// 一次危险命中：`code` 是稳定的机器可读标识（iOS 端据此本地化文案），
/// `detail` 是命中的原始片段，供用户看到具体命令上下文。
struct DangerHit: Codable, Equatable {
    var code: String
    var detail: String
}

/// 危险命令检测器：本地内置的模式匹配，**不信任 agent 自报**。
///
/// 检测点是「命令进入 agent 之前」—— 用户在 iPhone 上发的消息正文。
/// 受限于 opencode 是黑盒 TUI（内部调用哪些工具我们看不到），
/// 只能拦"入口"，无法拦"agent 在会话中途自行推断出的 shell 命令"；
/// 这已经是当前架构下能做到的最诚实的 L3 简化版。
enum DangerPattern {
    /// 危险规则表。`code` 保持稳定，改动只加不减（避免已持久化的 alwaysAllow 失效）。
    /// `pattern` 是正则，`extract` 从原文里摘一段人类可读的命中片段。
    private static let rules: [(code: String, pattern: String, hint: String)] = [
        // 最高危：删除根 / 家目录
        ("rm_root", #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-rf|-fr|--recursive\s+--force)\s+/(\s|$)"#, "rm -rf /"),
        // 递归删除
        ("recursive_delete", #"rm\s+(-rf|-fr|--recursive|-R)\b"#, "recursive delete"),
        // 强制推送（--force-with-lease 是安全变体，单独排除）
        ("force_push", #"git\s+push\b[^\n]*--force(?!-with-lease)"#, "git push --force"),
        // 硬重置
        ("git_reset_hard", #"git\s+reset\s+--hard\b"#, "git reset --hard"),
        // 管道执行远程脚本
        ("pipe_to_shell", #"(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#, "curl | sh"),
        // 提权
        ("sudo", #"\bsudo\b"#, "sudo"),
        // 开放权限
        ("chmod_777", #"chmod\s+(-R\s+)?0?777\b"#, "chmod 777"),
        // 写设备
        ("write_device", #">\s*/dev/"#, "write to /dev/"),
        // 磁盘镜像写入
        ("dd_disk", #"\bdd\s+if="#, "dd if="),
        // 破坏性数据库操作
        ("drop_table", #"\bdrop\s+table\b"#, "DROP TABLE"),
        ("truncate_table", #"\btruncate\s+table\b"#, "TRUNCATE TABLE"),
    ]

    /// 检测文本里命中的危险操作，返回命中的 `DangerHit` 列表（可能为空）。
    static func detect(in text: String) -> [DangerHit] {
        var hits: [DangerHit] = []
        for rule in rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                hits.append(DangerHit(code: rule.code, detail: rule.hint))
            }
        }
        return hits
    }

    /// 所有已知的 danger code，供「总是允许」清单做校验（拒绝未知 code 注入）。
    static var knownCodes: Set<String> {
        Set(rules.map { $0.code })
    }
}
