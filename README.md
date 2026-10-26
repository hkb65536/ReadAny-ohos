# ReadAny-ohos

[ReadAny](https://github.com/codedogQBY/ReadAny) 的 **HarmonyOS（ArkTS）原生移植** —— WebDAV 同步、阅读、书签、笔记。

## 这是什么

上游 ReadAny 是一个 AI 驱动的跨端电子书阅读器。本仓库把它四个核心功能**原生重写**到 HarmonyOS，
不是套壳、不是 WebView：界面用 ArkUI 绘制，本地库用 `@ohos.data.relationalStore`，
凭据用 `@ohos.security.asset`，阅读器用 Reader Kit（`ReadPageComponent` + `bookParser`）。

同步**逐字段复用上游协议**，没有新协议、没有版本协商，目的是与桌面端直接互通：

| 远端路径 | 内容 |
| --- | --- |
| `/readany/sync/index.json` | `schemaVersion:2`，`books` + `threads`，逐字段 max 合并 |
| `/readany/sync/books/{id}.json` | 行 + 标注 + `deleted` 墓碑映射 |
| `/readany/sync/profile/{table}.json` | profile 表（当前为 `book_groups`） |
| `/readany/data/books/{title}-{id}/` | 二进制与封面 |
| `/readany/data/file-manifest.json` | 大小 / 哈希 / 封面来源路径 |

## 工程结构

本仓库根目录就是鸿蒙工程根目录。

| 模块 | 类型 | 内容 |
| --- | --- | --- |
| `entry` | HAP | 页面与主题：书架、阅读器、标注、同步设置 |
| `core` | HAR | 定位符、CFI、错误类型、通用工具 |
| `data` | HAR | 数据层（DDL + 仓储）、导入、同步引擎 |
| `sync` | HAR | WebDAV 传输层、PROPFIND 解析、远端命名 |

依赖单向：`core ← sync ← data ← entry`（`sync` 不依赖 `data`）。

## 构建

需要 DevEco Studio 与 HarmonyOS SDK（`compatibleSdkVersion` 6.1.1(24)、`targetSdkVersion` 26.0.0、
`runtimeOS` HarmonyOS）。**路径不写死**：`build.bat` 按「`DEVECO_HOME` 环境变量 → 仓库根
`AGENTS.local.md` → 常见安装路径探测」的顺序找 DevEco Studio（规则见 [AGENTS.md](AGENTS.md) §0，
解析逻辑在 `scripts/env.ps1`）：

```powershell
# 首次在新机器上：复制本机环境模板并填写（此文件不入库，每台机器一份）
Copy-Item AGENTS.local.md.example AGENTS.local.md
.\scripts\env.ps1 -Print    # 确认 DEVECO_HOME / READANY_REF / PROXY 解析正确

# 先装依赖（ohpm）
& "$env:DEVECO_HOME\tools\ohpm\bin\ohpm.bat" install --all
# 再构建
.\build.bat assembleHap --mode module -p product=default
```

产物在 `entry/build/default/outputs/default/entry-default-unsigned.hap`。

**这个包是未签名的**（hvigor 会打印 `Will skip sign 'hos_hap'`），需要自己用 DevEco Studio 的
自动签名来安装。构建产物不入库，见 `.gitignore`。

## 开源协议

本仓库是 ReadAny 的**衍生作品**，整体按 **GPL-3.0-or-later** 发布：

- 上游版权：© 2024 ReadAny Team（GPL-3.0-or-later）
- 本移植的修改：© 2026 hkb65536
- 协议全文见 [LICENSE](LICENSE)，版权与修改声明见 [NOTICE](NOTICE)

GPLv3 是强 copyleft：任何人都可以自由使用、修改、再分发本仓库，但**衍生作品必须同样以
GPL-3.0 开源**，并保留上述声明。
