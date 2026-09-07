import Foundation

/// 从 Agent 执行输出中识别真实失败原因。
/// 不靠超时猜测，只从 CLI 实际返回的文本中匹配已知错误模式。
enum ErrorClassifier {
    static func classify(output: String, exitCode: Int32?) -> BrewPingProtocol.FailureReason? {
        let lower = output.lowercased()

        // 配额 / 信用 / 计费
        if containsAny(lower, [
            "quota exceeded", "quota has been exceeded", "insufficient credits",
            "insufficient_quota", "billing", "usage limit", "limit reached",
            "out of credits", "credit balance", "spending limit"
        ]) {
            return .quotaExceeded
        }

        // 认证失败
        if containsAny(lower, [
            "authentication failed", "unauthorized", "invalid api key",
            "invalid_api_key", "api key", "401", "permission denied",
            "access denied", "forbidden", "403"
        ]) {
            return .authenticationFailed
        }

        // 限流
        if containsAny(lower, [
            "rate limit", "rate_limit", "too many requests", "429",
            "retry-after", "retry after", "slow down"
        ]) {
            return .rateLimited
        }

        // 网络错误
        if containsAny(lower, [
            "network error", "econnrefused", "econnreset", "connection refused",
            "connection reset", "connection timed out", "dns resolution",
            "could not connect", "failed to connect", "socket hang up",
            "getaddrinfo", "bad gateway", "502", "503", "504"
        ]) {
            return .networkError
        }

        // Provider 错误（排除上面已分类的）
        if containsAny(lower, [
            "provider error", "server error", "internal server error",
            "500", "service unavailable", "model not found",
            "model_not_found", "invalid request", "context length",
            "maximum context", "token limit"
        ]) {
            return .providerError
        }

        // 进程退出（无匹配错误模式，但 exitCode 非零）
        if let code = exitCode, code != 0 {
            return .processExited
        }

        return nil
    }

    /// 从失败结果中提取人机友好的摘要（截取 CLI 输出前 120 字符）。
    static func summarize(output: String, reason: BrewPingProtocol.FailureReason) -> String {
        switch reason {
        case .quotaExceeded: return reason.message
        case .authenticationFailed: return reason.message
        case .rateLimited: return reason.message
        case .networkError: return reason.message
        case .providerError: return reason.message
        case .timeout: return reason.message
        case .modelUnavailable: return reason.message
        case .processExited:
            let firstLine = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return firstLine.isEmpty ? reason.message : String(firstLine.prefix(120))
        case .unknown:
            let firstLine = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return firstLine.isEmpty ? reason.message : String(firstLine.prefix(120))
        }
    }

    private static func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }
}
