#!/usr/bin/env python3
"""
本地化一致性校验（防止 EXC_BAD_ACCESS 级别的崩溃）。

背景：
    SwiftUI 的 `Text("... \\(x) ...")` 走 LocalizedStringKey，运行时会用
    当前语言的 .lproj 文案作为 format string 去填充实参。
    如果某个语言的译文里 %@ 的个数**多于**代码里的插值个数，
    Foundation 会去读栈上不存在的实参 —— 表现为
    `EXC_BAD_ACCESS (code=1, address=0x1)`，且崩溃点在函数签名里，
    不显示任何本地化相关信息，极难定位。

本脚本检查三类问题：
    A. 同一 key 在 en / zh-Hans 里占位符数量不一致      —— 会崩
    B. 代码中 Text/Button/... 的插值个数与译文不符      —— 会崩
    C. 某个 key 只存在于一个语言文件                    —— 不崩，但会漏翻

用法：
    python3 ios/Scripts/check_localization.py
退出码：0 = 通过；1 = 发现会崩的问题。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]  # 仓库根
TARGETS = [
    ("iPhone", ROOT / "ios/BrewPing", ROOT / "ios/BrewPing/en.lproj/Localizable.strings",
     ROOT / "ios/BrewPing/zh-Hans.lproj/Localizable.strings"),
    ("Watch", ROOT / "ios/Watch", ROOT / "ios/Watch/en.lproj/Localizable.strings",
     ROOT / "ios/Watch/zh-Hans.lproj/Localizable.strings"),
]

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
# 代码里的 UI 文案入口（这些位置接受 LocalizedStringKey，会被 SwiftUI 格式化）
UI_CALL = re.compile(r'\b(?:Text|Button|Label|NavigationTitle|Section|Toggle|Picker)\(\s*"((?:[^"\\]|\\.)*)"')
INTERP = re.compile(r'\\\(')


def parse_strings(path):
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    # 去掉 // 与 /* */ 注释，避免把注释内容误当条目
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return {k: v for k, v in ENTRY.findall(text)}


def count_ph(s):
    return len(re.findall(r'%@|%\d+\$@', s))


def find_L_calls(text):
    """找出所有 `L("key", arg1, arg2, ...)` / `LW(...)` 调用。

    返回 [(行号, (key, 实参个数)), ...]。
    需要处理跨行调用与嵌套括号（如 `L("x", foo(bar))`）。
    定义处 `func L(_ key: ...)` 与注释里的示例会被跳过。
    """
    results = []
    call = re.compile(r'(?<![A-Za-z0-9_.])LW?\(')
    for m in call.finditer(text):
        # 跳过注释行与函数定义
        line_start = text.rfind('\n', 0, m.start()) + 1
        line_head = text[line_start:m.start()]
        if '//' in line_head or 'func ' in line_head:
            continue
        # 从 '(' 开始做括号平衡，注意跳过字符串字面量里的括号
        i = m.end()
        depth = 1
        in_str = False
        escape = False
        while i < len(text) and depth > 0:
            c = text[i]
            if escape:
                escape = False
            elif c == '\\':
                escape = True
            elif c == '"':
                in_str = not in_str
            elif not in_str:
                if c in '([':
                    depth += 1
                elif c in ')]':
                    depth -= 1
            i += 1
        inner = text[m.end():i - 1]
        # 按顶层逗号切分
        parts, buf, d, s, e = [], [], 0, False, False
        for c in inner:
            if e:
                e = False
            elif c == '\\':
                e = True
            elif c == '"':
                s = not s
            elif not s:
                if c in '([':
                    d += 1
                elif c in ')]':
                    d -= 1
                elif c == ',' and d == 0:
                    parts.append(''.join(buf))
                    buf = []
                    continue
            buf.append(c)
        parts.append(''.join(buf))
        if not parts:
            continue
        first = parts[0].strip()
        if not first.startswith('"'):
            continue  # 动态 key，无法静态校验
        key = first.strip('"')
        n_args = len([p for p in parts[1:] if p.strip()])
        lineno = text.count('\n', 0, m.start()) + 1
        results.append((lineno, (key, n_args)))
    return results


def main():
    fatal = 0
    warn = 0

    for label, src_dir, en_path, zh_path in TARGETS:
        en, zh = parse_strings(en_path), parse_strings(zh_path)
        print(f"\n===== {label} (en={len(en)}, zh={len(zh)}) =====")

        # A. 同一 key 两侧占位符数量不一致
        for key in sorted(set(en) & set(zh)):
            ne, nz = count_ph(en[key]), count_ph(zh[key])
            if ne != nz:
                fatal += 1
                print(f"  [FATAL] 占位符数量不一致: {key!r}")
                print(f"          en({ne}) = {en[key]!r}")
                print(f"          zh({nz}) = {zh[key]!r}")

        # C. 单侧缺失
        for key in sorted(set(zh) - set(en)):
            warn += 1
            print(f"  [WARN ] en 缺少 key（中文会回退原文）: {key!r}")
        for key in sorted(set(en) - set(zh)):
            warn += 1
            print(f"  [WARN ] zh 缺少 key（中文会显示英文）: {key!r}")

        # B. 代码插值个数 vs 译文占位符个数
        for swift in sorted(src_dir.glob("*.swift")):
            text = swift.read_text(encoding="utf-8")
            for lineno, line in enumerate(text.splitlines(), 1):
                if "Log." in line:  # 日志不走本地化格式化
                    continue
                for m in UI_CALL.finditer(line):
                    raw = m.group(1)
                    if not INTERP.search(raw):
                        continue
                    n_interp = len(INTERP.findall(raw))
                    key = re.sub(r'\\\([^()]*\)', '%@', raw)
                    # 译文中的占位符多于插值个数 → 必崩
                    for tbl_name, tbl in (("en", en), ("zh", zh)):
                        if key in tbl and count_ph(tbl[key]) > n_interp:
                            fatal += 1
                            print(f"  [FATAL] {swift.name}:{lineno} 译文占位符多于代码插值")
                            print(f"          代码插值={n_interp}  {tbl_name}={tbl[key]!r} ({count_ph(tbl[key])} 个)")

        # B2. `L("key", 实参...)` 的实参个数 vs 译文占位符个数
        #     SwiftUI 那一路只在插值多于译文时崩；这里 String(format:) 相反 ——
        #     译文占位符多于实参就会读栈上垃圾。两种情况都要查。
        for swift in sorted(src_dir.glob("*.swift")):
            text = swift.read_text(encoding="utf-8")
            for lineno, args in find_L_calls(text):
                key, n_args = args
                for tbl_name, tbl in (("en", en), ("zh", zh)):
                    if key in tbl and count_ph(tbl[key]) > n_args:
                        fatal += 1
                        print(f"  [FATAL] {swift.name}:{lineno} L() 实参不足")
                        print(f"          {key!r} 需要 {count_ph(tbl[key])} 个，实际传了 {n_args} 个"
                              f"（{tbl_name} 译文 = {tbl[key]!r}）")

    print()
    if fatal:
        print(f"❌ 发现 {fatal} 处会导致崩溃的问题 —— 必须修复。")
        return 1
    print(f"✅ 无崩溃风险。" + (f"（另有 {warn} 处漏翻提示）" if warn else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
