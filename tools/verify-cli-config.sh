#!/bin/bash
# 「厂商原生配置」四模块的不变量验证。
#
# 为什么不用 `swift test`：XCTest / swift-testing 都随 Xcode 提供，
# 本机只有 Command Line Tools 时 `import XCTest` 直接报 "no such module"。
# 这里把「四个模块 + 基础设施」的源文件与验证器一起交给 swiftc 编译执行 ——
# 这 6 个文件只依赖 Foundation，可以独立编译。
#
# 用法：./tools/verify-cli-config.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/verify-cli-config"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "编译验证器…"
xcrun swiftc -O -o "$OUT" \
  Sources/App/CLIConfigSupport.swift \
  Sources/App/MiniTOML.swift \
  Sources/App/ClaudeProviderConfig.swift \
  Sources/App/CodexProviderConfig.swift \
  Sources/App/PiProviderConfig.swift \
  Sources/App/OpenCodeProviderConfig.swift \
  tools/verify-cli-config.swift

echo "运行…"
echo ""
"$OUT"
