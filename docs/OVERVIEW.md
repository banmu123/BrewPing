# Documentation map

What lives where, and which document wins when two of them disagree.

## Source of truth

**[PROJECT_STATUS.md](PROJECT_STATUS.md)** is the single place for objective state: platform
requirements, distribution status, test counts, CI jobs, and known limitations. Everything else —
`README.md`, `README.zh-CN.md`, `ROADMAP.md`, `CONTRIBUTING.md` — either summarises it or links here.
If a number appears in two files and they disagree, this one is right and the other file is a bug.

To avoid drift, the READMEs deliberately **do not** repeat test counts or release stages; they show
the commands and link here.

## Layout

```
docs/
├── PROJECT_STATUS.md      # canonical status (platforms, tests, CI, limitations)
├── privacy.html           # the privacy policy shipped with the app
├── screenshots/           # the two images used by the READMEs
├── design/                # how the product is built
│   ├── BrewPing-iOS端结构与模块划分.md
│   ├── BrewPing-Windows端多对话管理实现方案.md
│   ├── BrewPing-Provider管理-Lody新建Provider迁移方案.md
│   ├── BrewPing-获取文件夹-Windows落地方案.md
│   ├── BrewPing-WearOS端开发准备清单.md
│   ├── BrewPing-安全传输方案.md          # proposal, not implemented
│   └── BrewPing-设备授权与撤销方案.md    # proposal, not implemented
└── audits/                # point-in-time reviews, kept as records
    ├── BrewPing-安全审计-第二批.md
    ├── BrewPing-代码审查-Phase1-审计.md
    ├── BrewPing-Android-iOS-功能对齐审查.md
    ├── AppStore-PreSubmission-Review.md
    ├── TestFlight-Validation-Report.md
    └── BrewPing-iOS-TestFlight-自动发现-诊断.md
```

Documents under `design/` and `audits/` describe a moment in time. They are **not** status
statements — a design doc marked "proposal" may still be unimplemented, and an audit may list issues
that have since been fixed. Check `PROJECT_STATUS.md` before drawing conclusions about today.

## Not product documentation

- `.workbuddy/memory/` — the maintainer's development log (append-only). Kept in the repository as
  working context; it is not user-facing documentation.
- `.workbuddy/outputs/` — screenshots and reports captured while verifying fixes. Historical
  evidence, not product material.
- `experimental/` — prototype code, outside the product and security boundary.
