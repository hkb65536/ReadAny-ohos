# AGENTS.md — InkBoat

> 这份文件是**跨会话的长期记忆**。它记录这个项目**已经付出代价换来的事实**，目的是让下一个 agent（或下一轮的我）不必重新踩一遍。
>
> **维护规则**：每轮结束时，如果产生了「不该再被重新推导」的事实，就补进来。宁简勿漏关键项。
>
> **打码约定**：文中出现 `<vps-ip>` / `<device-ip>` / `<hdc-port>` / `<github-email>` / `<github-user-id>` 的地方是**刻意打码**的（服务器地址、测试设备地址、联系方式）。**需要这些真实值时直接问用户要** —— 不要去 git 历史里翻、不要从别的文件推断、也不要猜。

---

## 1. 这个项目是什么

把 **ReadAny**（一个桌面端电子书阅读器）的四个核心功能**原生移植**到 HarmonyOS：

**WebDAV 同步 · 阅读 · 书签 · 笔记**

- 工作目录：`D:\Code\ReadAny-ohos`
- 鸿蒙工程：**与工作目录同一个目录** —— 仓库根就是工程根（`build-profile.json5`、`build.bat`、`entry/`、`core/`、`data/`、`sync/` 直接在最外层）。**旧的 `harmony/` 子目录布局已不存在**
- 参照实现：**`D:\Code\ReadAny`**（[codedogQBY/ReadAny](https://github.com/codedogQBY/ReadAny)），**只读，绝不修改**。**已固定在 `v1.3.6`**（分支 `pinned-v1.3.6`，commit `8d3f74a1`），v1.3.6 之后的提交与分支引用**已从本地清除** —— 见 §12.8
- 调研产出 `docs/`、诊断/证据/探针脚本 `.diag/`、审计套件 `tools/`：**都不在本仓库**。文中这些路径是**历史记录**；`tools/` 缺失意味着 §3.2 的 30 工具审计在本工作区跑不了
- **代码托管**：**仓库根自己就是 git 仓库**（`D:\Code\ReadAny-ohos\.git`，就地 `git init`），`origin` = `https://github.com/hkb65536/ReadAny-ohos.git`，分支 `main` —— 详见 **§12**

> **⚠️ 路径口径（2026-10-26 统一）**
>
> 本文档 r95–r122 的轮次记录写于**旧工作区**（原 `D:\Code\InkBoat`）+ `harmony/` 子目录布局，所以历史段落里仍会出现 `harmony/entry/…` 这类写法。**在本仓库里一律这样读**：`harmony/<x>` → `<x>`（仓库根下的同路径，例见下一行），工作区一律是 `D:\Code\ReadAny-ohos`。
>
> 例：`harmony/entry/src/main/ets/pages/ShelfPage.ets` = `entry/src/main/ets/pages/ShelfPage.ets`；`harmony/entry/build/…/entry-default-unsigned.hap` = `entry/build/…/entry-default-unsigned.hap`（后者才是本仓库的真实产物路径）。
>
> 本轮只改**现行生效**的路径（§1、硬约束、§3 命令、§4.2、§12）与产物路径；历史轮次的正文保留原文，以保持「当时到底跑了什么」可追溯。

> **⚠️ 参照实现的版本口径（2026-10-26，r124）**
>
> `D:\Code\ReadAny` **不是 main**，是 **`v1.3.6`** 的标签提交。两个直接后果：
> 1. **v2 协议在 v1.3.6 里不存在** —— `packages/core/src/sync/per-book-sync.ts`（1085 行）是 **main 独有**，main 比 v1.3.6 领先 **77 个提交**。所以「已发布的桌面端只讲 v1」这条前提现在有本地证据，不再是从别处推断的。
> 2. **本文档里 `simple-sync.ts:396-418` 这类行号是 main 的行号**。在 v1.3.6 检出里，`if (!options.forceApply && deletedAt > 0)` 在 **:381**、`if (deletedAt > 0)` 在 **:393** —— 语义一致（`deletedAt <= 0` 时整段 `if` 被跳过，那条 DELETE 无条件执行）。

- **开源协议**：本移植是 ReadAny（**GPL-3.0-or-later**）的衍生作品，`LICENSE`/`NOTICE`/`README.md` 已补齐并推送 —— 详见 **§12.6**

### 用户的核心约束（原话）

> `targetSdkVersion 26`、`compatibleSdkVersion 24`、`runtimeOS HarmonyOS`；阅读器用 Reader Kit（`ReadPageComponent` + `bookParser`）；同步完全复用 ReadAny 现有 WebDAV 协议；凭据存 `@ohos.security.asset`；本地库用 `@ohos.data.relationalStore`。

### 用户的工作方式偏好

- **以 ReadAny 的行为为准**（有疑问先去读 ReadAny 的实现，再决定）
- **先调研可行性、给出方案让他确认，之后才动代码**
- **他手动安装**（见 §3.4）
- 写代码前先问，不要擅自开始

---

## 2. 绝不能碰的东西（硬约束）

| # | 约束 | 为什么 |
|---|---|---|
| 1 | **绝不修改另行检出的上游 `ReadAny/` 下任何文件** | 它是参照物。若本机检出过，每轮结束可用 `git -C <ReadAny 路径> status --porcelain` 应为空 + 无今日 mtime 来自证。**现在已检出在 `D:\Code\ReadAny`，固定 `v1.3.6`，只读** |
| 2 | **不动 `data/src/main/ets/Rdb.ets` 的 `queueBusy` 重入守卫**（声明 ~:117，置位 :131，清除 :135，早返回 :138） | 它修掉了一个**已验证的死锁**：`runWithRetry` 把写入串行化，而 `updateReadingPosition` 在事务里调 `getDeviceId()`，后者在冷缓存时排到自己后面 → **所有写入（设置、`last_sync_at`、阅读位置）全部静默卡死**。表现为 `start` 打 3 次而 `done`/`failed` 0 次、WAL 冻结在 0 字节 |
| 3 | **三个破坏性同步操作只存在于注释**：`cleanupRemoteOrphans`、`cleanupLocalOrphans`、`migrateBookRemoteState` | 由 `tools/verify-sync-routing.mjs` 断言（它从 `WebDavClient.ets` 反推传输层的删除/移动方法名）。**远端从不发出删除**；`deletePath` 零调用者 |
| 4 | **绝不设 `forceApply`** | `SyncRouter.ets:196` = false，`SyncV1.ets:383` = false |
| 5 | **不削弱墓碑上界**（`SyncConstants.ets` 的 `MAX_FUTURE_TOMBSTONE_SKEW_MS`） | `tools/verify-tombstone-bound.mjs` 守着 |
| 6 | **不改同步线格式** | 要和桌面端互通 |
| 7 | **备份一律放仓库根目录**（`D:\Code\ReadAny-ohos\.backup-*`），**绝不放模块目录里** | 审计工具扫各模块 `src/` 下的源码，**放在里面的备份会被当成活代码**，已经因此造成过一次审计失败 |
| 8 | **绝不用进程名杀进程**（`Get-Process node \| Stop-Process` 曾杀掉开发宿主） | |
| 9 | **绝不写 `while (t.includes(a)) { t = t.replace(a,b) }`**（当 `b` 含 `a` 时死循环，曾挂住工具链） | 用 `t.split(a).join(b)` |
| 10 | **做全局替换前确认「替换文本里不含搜索文本」** | 曾有一次性把 `goToSettingsPage` 的函数体改成调用它自己，造成无限递归崩溃 |
| 11 | **阅读器的硬约束见 §6** | 每一条都是真机验证过的 |

### 同步的三条铁律（永不违反）

1. **绝不从「我的库里没有这条」推断出「它被删了」**
2. **绝不发出 `deletedIds` 却没有配对的 `deletedTimestamps`，且时间戳必须是有真实毫秒值 `> 0`**
3. **绝不在 `deletedIds` 非空时给出空/缺失的 `deletedTimestamps`**

**接收端（r121 更正：原来那句话只描述 ReadAny，不描述我们）。** ReadAny 的时间戳守卫**只在 `deletedAt > 0` 时才存在**（`ReadAny/packages/core/src/sync/simple-sync.ts:396-418`，**这是 main 的行号；v1.3.6 检出里在 `:381`/`:393`**，形状是 `const deletedAt = tableData.deletedTimestamps?.[deletedId] ?? 0; if (!options.forceApply && deletedAt > 0) { … if (localTs > deletedAt) { skip } }`，之后直接 `DELETE FROM …`）——**`deletedAt <= 0` 把整个 `if` 跳过，于是那条 DELETE 是无条件的**。

**我们自己的实现有四道闸门，都在 `SyncV1.ets`**：`:1345`（同一 payload 里有活跃行 ⇒ 当作过期墓碑）、`:1356`（`unjustifiedDeletions`：`deletedTimestamps` 里没有有效值 ⇒ 拒绝）、`:1368`（`isPlausibleTombstone` ⇒ 忽略）、`:1383`（`deletedAt >= localUpdatedAt`，见 `ShouldApply.ets:111-116`）。**所以 `deletedAt <= 0` 的 DELETE 路径在我们代码里不可达。** 与参照实现对照（**时间戳那侧：它一道、我们三道，多三道**）：`unjustifiedDeletions`、`isPlausibleTombstone`，以及把顺序比较放到 `deletedAt > 0` 之外跑（参照实现只在正时间戳时才比较）；第四道 `:1345` 两边都有——参照实现在 `simple-sync.ts:387-394` 对同一 payload 里的活跃行同样跳过。

**结论不变**：对 `books` 而言，那条 DELETE（在参照实现里可达）会通过 `ON DELETE CASCADE` **静默摧毁标注且不留墓碑**。**所以三条铁律照旧。**

---

## 3. 环境与工具链

### 3.1 构建

```powershell
cd D:\Code\ReadAny-ohos
$env:DEVECO_SDK_HOME="D:\DevEco Studio\sdk"
& "D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default --no-daemon
```

- DevEco Studio 26.0 在 `D:\DevEco Studio`，SDK 在 `D:\DevEco Studio\sdk`
- **`hvigorw` 从不打印 `COMPILE RESULT:`**——那个字符串来自某个包装脚本，别去找它
- **`clean` 和 `incremental` 构建不是逐字节相同的**：产物只在 `ets/modules.abc` 和 `ets/sourceMaps.map` 上不同（约 ±13 字节）。**所以 hash 标识的是磁盘上那个文件，不是可复现构建**
- 模块：`entry`(HAP) + `core` + `data` + `sync`(HAR)，**单向依赖 `core ← sync ← data ← entry`**；**`sync` 绝不能 import `data`**

### 3.2 审计套件

```powershell
cd D:\Code\ReadAny-ohos
Get-ChildItem tools -File | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name | ForEach-Object { & node $_.FullName 2>&1 | Select-String 'passed' }
```

**前提：`tools/` 在本工作区不存在**（审计套件没有随仓库发布，`Get-ChildItem tools` 会报路径不存在）。若另行恢复了它，再从仓库根 `D:\Code\ReadAny-ohos` 跑上面那段。

**必须逐工具相加并手工核对。** 反复出错的点：

- **`Select-String 'passed'` 对 30 个工具返回 34 行**，因为**有四个工具会打印包含 "passed" 的非计数行**：
  `verify-objective-coverage`（"no documentation found; currently passed as 1"）、`verify-streaming-download`（"ok a path with no parent is not passed to mkdir"）、`verify-sync-routing`（"ok an empty path is passed through"）、**`verify-reader-chrome`**（其 MEASURED 注记含 "a passed #121212"）
- **`& $_.FullName` 不产出任何东西**，必须 `& node $_.FullName`
- **汇总行的格式是 `N/M <前缀词> checks passed, K failed.`**，前缀词会让 `(\d+)/(\d+) checks passed` 这种简写**漏掉 8 个工具**（r99 实测：漏掉时合计 1990，正确合计 3410）。正确正则、以及**「34 行口径」与「30 行口径」的区别**见 **§12.5**
- 历史基线一路长到这里：**30 工具 / 3744 项 / 3744 通过 / 0 失败**（**r120 实测，30 行口径**）。完整沿革：`3289/0`（材质探针之前）→ `3412/3410/2 失败`（r99，材质探针在场，那两条失败是探针自身的 `MaterialLevel`）→ **`3459/0`（r100，探针删除 + 本轮新增/改写的断言）** → `3524/0`（r102）→ `3553/0`（r106）→ `3580/0`（r107）→ `3604/0`（r112）→ **`3599/0`（r113，**下降** 5：删除 r110 的入场动画，`verify-motion` 153 → 148）** → `3621/0`（r114）→ `3623/0`（r115）→ `3633/0`（r116：`verify-reader-chrome` 402 → 410、`verify-sync-progress` 151 → 153）→ `3706/0`（r117）→ `3726/0`（r118：`verify-book-menu` 239 → 257、`verify-reader-chrome` 410 → 412、`verify-motion` 148 → 148）→ `3739/0`（r119：`verify-book-menu` 257 → 266、`verify-themes` 226 → 230）→ **`3744/0`（r120：**只** `verify-book-menu` 266 → 271，其余 29 个工具逐条相同）**。**注意 r113 那一步是负增长** —— 「总数只增不减」不是不变量，删特性时它会掉。

**变异测试（下划线开头，审计循环会跳过）**：`_mutate-sync-v1.mjs` 19/19、`_mutate-sync-progress.mjs` 18/18、`_mutate-sync-routing.mjs` 39/39、`_arkts-extract.mjs`（共享的受保护提取器）；**按轮次的在 `.diag/`**：`.diag/r118-mutate.mjs` 26/26、`.diag/r119-mutate.mjs` **27/27（4 条 control 全绿、0 条 NOT APPLIED、5 个源文件 sha256 逐字节还原）**、`.diag/r120-mutate.mjs` **22/22（3 条 control 全绿、0 条 NOT APPLIED、4 个源文件 sha256 逐字节还原；含 4 条专用「标题回不来」变异）**。锚点唯一性先验脚本：`.diag/r120-anchors.mjs`（22/22 unique）。

### 3.3 文档与知识库 —— **优先走 MCP**

**有一个 Huawei 知识库 MCP，必须优先于抓网页使用**：

```
mcp__harmonyos_developer_knowledge__searchDocuments     ← 用中文查（中文明显更有效）
mcp__harmonyos_developer_knowledge__getDocumentsById    ← 传 search 返回的 parent 值（一次最多 10 个）
```

**关键：这个 MCP 的健康检查会说谎。** `mcp_connector_health_check` 对它会报 `not-configured`，**即使连接完全正常**。**不要因为健康检查失败就断定它不可用，直接调 `searchDocuments`——真实调用成功。** 曾经因为跑了健康检查、看到失败、然后转去抓网页，白白浪费了轮次。

**只有 MCP 真的查不到时才回退到 `web_fetch`。** 已知可用的文档 URL 规则：

- `https://developer.huawei.com/consumer/cn/doc/doccenter-<collection>/<page>.md`
- `<collection>` 可为 `references` / `capabilities` / `ux-design`（**设计集合是 `ux-design`；`docs-design-guides` 是 404**）
- 集合索引：`https://developer.huawei.com/consumer/cn/llms/docs-<collection>.txt`，入口 `https://developer.huawei.com/config/llms.txt`

**证据优先级：实现/声明 > 官方参考文档 > 文档里的散文注释。** 散文注释会过期——比如 `common.d.ts` 里 `SheetSize.MEDIUM` 那句 "height is half the screen height" 是 API 10 时代的陈旧文本，**真实值是 60%**（MCP 参考 + `sheet_theme.h` 的 `mediumPercent_ = 0.6` 两处独立来源对上）。

### 3.4 设备与安装

- 设备：**`CMM-AL10P`**（Mate 90 Pro Max），HarmonyOS `7.0.0.109(SP9C00E108R6P4)`，**API 26**
- 屏幕 **1320×2848 px，密度 3.375 px/vp**（densityDPI 540），**宽 391.1 vp**
- bundle：`com.readany.reader`
- `hdc.exe`：`D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`（**不在 PATH 里，要用全路径**）
- **TCP 端口每次会话会变**：先 `hdc list targets -v`，取 `Connected` 那一行
- **设备会在会话中途断开**（`list targets` 变 `[Empty]`）。**任何依赖设备的脚本都要先检查 `Connected` 再动手**——曾经因为没检查，一个采样脚本拿到的图片对象是空的，刷了满屏 `You cannot call a method on a null-valued expression`，而真正的原因只是设备不在。**重新连上后地址可能和之前相同，但不要假设。**
- **包无签名，agent 装不了**。`build-profile.json5` 是 `"signingConfigs": []`，hvigor 会打 `Will skip sign 'hos_hap'`。**用户用 DevEco 自动签名安装。每一轮都需要用户装一次，这是既定流程。**
  - 曾经尝试过用 SDK 自带的 OpenHarmony 测试签名材料（`toolchains\lib\OpenHarmony.p12` 等）自签——**用户决定不走这条路，继续手动装**。根因：HarmonyOS 商用设备一般不信任 OpenHarmony 测试根。
  - 仓库根那个 `hokit_debug.cer` **是一张自签名根 CA 证书**（issuer == subject），**不是签名证书，签不了 HAP**。签 HAP 需要 `.p12` + `.cer` + `.p7b` 三样。

**设备操作**：

| 目的 | 命令 |
|---|---|
| 启动 | `aa start -b com.readany.reader -a EntryAbility` |
| 截图 | `snapshot_display -f /data/local/tmp/x.jpeg` 然后 `hdc file recv` |
| 点击 | `uinput -T -c <x> <y>` |
| 滑动 | `uinput -T -m <x1> <y1> <x2> <y2> <speed>` |
| 清日志 | `hilog -r` |
| 读日志 | `hilog -x`（**含 kit 自己的 `A06666` 行，所以应用和 kit 的证据在同一份文件里**） |
| 防息屏 | `power-shell timeout -o 1800000` |

**`uinput` 的坑**：
- **前台切换后的第一次点击会被吞掉**——重要操作前先点一次，或同坐标点两次
- **滑动的终点 x 必须远离左边缘（> 约 200px）**，否则系统会当成返回手势
- **息屏后要 `power-shell wakeup`**；**如果出现锁屏/密码提示，停下来报告，不要猜**（`10106102` 是锁屏错误）

### 3.5 `pwsh` 的坑

- **`cd` 不跨调用持久**——用 `Set-Location` / `Push-Location`，或用 `workdir` 参数
- **`Select-String` 默认大小写不敏感**
- **不要给自动变量赋值**（`$PID`、`$HOME` 等，变量名大小写不敏感所以 `$home` 就是 `$HOME`）
- **SSH 命令串里避免 `$()`**
- **图片采样用 `Add-Type -AssemblyName System.Drawing` + `GetPixel`**，在 full-access 下可用

### 3.6 服务器（同步测试用）

- SSH 别名 **`2C2G`** → `root@<vps-ip>:22`
- 线上目录 `/srv/webdav/readany/`；测试副本 `/srv/webdav/readany-sync-test/`；备份 `/srv/webdav/readanybak/`（**已不存在（r121 实测）**——只保留这条实践记录，别再照着它去找）
- **只读授权；绝不写入**
- Apache WebDAV；日志 `/var/log/apache2/*access*.log`

**安全的测试协议**：关掉自动同步 → `cp -a readany readany-sync-test` → 远程目录指向 `readany-sync-test` → 跑一次 NORMAL 同步 → diff。**盯第一条进度行「拉取远端书籍（N 本）」，N 必须等于 `books` 键数。**

---

## 4. 项目纪律（踩坑换来的）

### 4.1 验证

1. **测量，不要目视。** 这个项目因为「目视判断颜色」被误导过**两次**。**采样像素**是决定性的。
   - 但**也要验证「量的是对的东西」**：曾经有一个测量脚本扫错了区域（扫的是旧底栏而不是目标胶囊），产出了 `311.1 × 41.8vp` 这个**被当成事实报出去的假数据**。**脚本跑出数字 ≠ 数字有意义。**
2. **「计数对上了」≠「代码是对的」。** 曾有一个「删除探针」的配方验证了行数和标识符计数，**但从没编译过结果**——而它其实删掉了两行真实代码、产出的文件**编译不过**。**验证必须验「结果可用」。**
3. **验证子代理的算术**，不要照抄。
4. **如实说明「无法验证的部分」**，不要含糊过去。
5. **绝不删除或削弱审计断言。** 设计变更强制反转断言时，**要反转成等价或更强的**，并说明改的是哪条、为什么。
6. **不要从「观察到的状态」推断行为。** 这个错误至少犯过四次，全部已撤回：
   - 读了 repo HEAD 而不是已发布 tag，就断言「ReadAny 当前用 v2 协议」
   - 断言「ReadAny 删掉了其他三台设备的文件」（实际是用户自己删了重传）
   - 「`file_path` 为空的记录会被跳过」这个假设——**在真机上被证伪**
   - 「Menu 不能承载材质」——**错的**，`MenuOptions.systemMaterial` 是合法的
7. **`BUILD_STAMP` 每轮必改。** 它有过两次没改，其中一次把调查引向了错误方向。
8. **子代理看不到你对话里的图片。** 要给它参考图，必须**用文字精确描述**。

### 4.2 代码

- **注释解释「为什么」，不是「是什么」**
- **大改之前先备份**（放仓库根，见硬约束 #7）
- **优先用 `edit` 工具做定点修改**，不要用行号切割脚本
- **改完代码就落到本地仓库**：只要改了代码，就在**仓库根** commit 一次（纪律与命令见 **§12.1**）。**一轮结束时工作区不允许留着未提交的代码改动。**
- **不要每次都推远端**：`git push` **只在用户明确要求时**执行（§12.1）。「本地领先远端若干提交」是正常状态，不是待办。
- **ArkTS 约束**（本工作区没有 `docs/arkts-constraints.md`；摘要就是下面五条）：
  - 无结构化类型；对象字面量无法实现跨模块接口
  - **无对象展开 / 无 `Object.assign`**
  - **无 `URL` 全局对象**
  - **`@Builder` 的函数体只接受 UI 组件语法（不能有 `const`、不能有语句）**
  - **`import type` 不能携带作为值使用的 `enum`**
- **符号资源名用下划线，绝不用点**
- **官方圆角**：`4` 标签/徽标、`8` 图片/图标、`16` 卡片/内容容器、`20` 按钮/菜单/页签、`32` 半模态/弹窗；规则是**同层统一 + 层级正相关**
- **`systemMaterial` 的规则**：通用属性只在 **`Navigation`/`NavDestination` 标题栏**或**横向 `Tabs` 且 `barPosition: BarPosition.End` 的底部 TabBar** 生效（运行时强制）。**绝不给页面大小的容器或小选中片加**（误犯过三次）。选项对象途径（`MenuOptions`/`SheetOptions` 等）对弹窗类合法；`Slider`/`Toggle`/`Select` 是**全页面生效**的例外。
  - **r118 补上了官方的原话与「补救办法」**（原来只有我们自己测出来的规则，没有出处）：开启沉浸光感那篇写的是「**其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感效果不生效。**」；而**沉浸光感常见问题**那篇的**解决措施**第一句就是「**将需要沉浸光感效果的组件置于 Navigation/NavDestination 标题栏…中**」，配的例子是「标题栏里的 `Column` 生效 / 内容区里同一个 `Column` 不生效」。
  - **所以「控件在内容区」不是死路，而是「把它搬进标题栏」**：`ShelfPage` 因此长了一个**没有内容、没有 `NavPathStack`、没有 destination、只当材质宿主**的 `Navigation`（形状照抄 `ReaderView.topBar`）。**这是本项目承载材质的标准做法**，下次遇到同类需求先想这条路，不要先想模糊。
  - 两条配套事实：① 材质要挂在**标题栏里的局部容器**上，不要挂在 bar 自身（功耗优化那篇的正例），也不要给 page 大小的容器；② **一个 `Search`/`Button` 自己的 `backgroundColor` 会盖住材质层**（材质视觉层级在 `backgroundColor`/`backgroundBlurStyle` **之下**），所以别指望「控件各自加材质再保留原填充」。
  - **r119 把「②」推到了它的结论，三条新事实（都有出处，别再重新推导）**：
    1. **控件要透明就必须显式写 `Color.Transparent`**。「不设 `backgroundColor`」**不等于**透明——未设背景的 `Button` 用框架自己的按钮色、**跟随系统色彩模式**，那正好是 r118 那颗黑圆片。删属性与写透明是两件不同的事。
    2. **`@ohos.arkui.uiMaterial` 的「表1 · 特殊资源值对应的深浅色值」是材质上唯一会自动反色的颜色集合**，它给出的可反色资源包括 `sys.color.brand` / `brand_font` / `warning` / `font_on_primary` / **`font_primary` `#E5000000`|`#E5FFFFFF`** / `font_secondary` / `font_tertiary` / `font_fourth` / `font_emphasize` / **`icon_primary`（与 `font_primary` 同值）** / `icon_secondary` / `icon_tertiary` / `icon_fourth` / `icon_emphasize` / `icon_sub_emphasize` / `comp_background_primary_contrary` / `comp_background_secondary` / `comp_background_tertiary` / `comp_background_emphasize` / …。**硬编码颜色（含调色板常量）永远不反色**——「使用硬编码的颜色值（如 Color.White、'#FFFFFFFF'）不会触发自动反色，仅对…特殊资源（见下表1）值时生效」。参与反色的属性清单也在同一处：`Text`/`Button`/`SymbolGlyph` 的 `fontColor`、`Image.fillColor`、`Search` 的 placeholder/font/searchIcon/cancelButton/caretStyle/searchButton、`Chip`/`ChipGroup`/`TextArea`/`TextInput`/`SegmentButton(V2)`/`Swiper`/`TabContent.tabBar`。**注意 `LoadingProgress.color` 不在清单里**（r119 的忙碌环因此是静态着色）。
    3. **`colorInvert` 默认 `false`**（`@ohos.arkui.uiMaterial.d.ts:380`，`@since 26.0.0`），**不显式打开，表1 的资源也只是静态解析**；它另有三个前提：**高/中算力**（低算力档不产生视觉差异）、**样式必须是 `THIN`/`ULTRA_THIN`**（`REGULAR`/`THICK`/`ULTRA_THICK` 不生效）、**系统沉浸光感的强弱**。功耗优化那篇的**正例**正是「**缩小反色范围，仅对需要保证可读性的局部区域开启**」，反例是「在包含大量子项的列表外层开启」——所以**只给标题栏里那个小容器开**。（r119 顺手记下的一个**很有用的性质**：本应用在 `Index.applySystemAppearance` 里**用应用主题强制系统色彩模式**（`const dark: boolean = this.themeMode === 'dark'`），所以亮色/护眼走系统浅色、暗色走系统深色——**表1 资源的静态解析本来就和材质背后的页面同调**，自动反色因此是**安全网**而不是机制。若把护眼映射成系统深色，近白字形会在 `#F5EBD7` 上掉到约 1.03:1 而消失。）
  - **命名纪律**：`backgroundBlurStyle`/`foregroundBlurStyle` 是**没有作用域限制**的通用属性，但它们给的是**静态毛玻璃**，**不是沉浸光感**。项目里凡是手搓的模糊（阅读器 sheet 外那层）**只能叫「毛玻璃/背景模糊」**，绝不能叫沉浸光感。
- **`verify-themes` 有一条全文件十六进制颜色扫描，它分不清注释和颜色**——**所以阅读器的注释里也不能写 `#RRGGBB`**（踩过一次：横幅注释里引用了颜色值，触发失败）。

---

## 5. 已建成的功能与已验证的行为

**全部在真机上验证过可用**：

- **v1 协议同步**（记录 + 文件双向）
- **阅读器**：位置保存/恢复、CFI 双向、书签/笔记跳转、UI、目录
- **TXT → EPUB 转换**（自制 zip 容器）
- **书籍操作菜单**（删除确认、沉浸光感材质、按卡片宽度推导的宽度）
- **无封面占位灰**（`placeholderSurface`/`placeholderForeground`）
- **三主题**（亮色/暗色/护眼），**阅读页跟随应用主题**
- **四个 sheet**（目录/书签/笔记/设置）：共享表头（大标题 + 圆形 ×）、半高、护眼主题下背景统一
- **阅读器浮动两栏 + 三分区点击覆盖层**（r100）：构建与审计通过，**尚未装机验收**——见 §9

**审计基线：30 工具 / 3744 项 / 3744 通过 / 0 失败**（**r120 实测，30 行口径**；r100 时是 3459，中间各轮的数与那次**负增长**见 §3.2 的沿革）

---

## 6. 阅读器的硬约束（每条都是真机验证过的）

1. **`init(context)` 必须早于 `registerBookParser`**；`startPlay` 又必须在 `registerBookParser` 之后。顺序错了会报 `Read Page Component is not initialized` (`1016900002`)
2. **`resolveViewPort()` 绝不能返回 0**——Reader Kit 会代入一个 61×62 的退化盒子并放大约 10.8 倍，**表现为一页一个大字**
3. **底栏必须从第一帧就画出来**。晚画会导致第一次分页用了一个高约 95vp 的盒子，**然后栏出现时在「读者已经开始读」的页面上重新分页**。修法是立刻画栏、把 `if (this.loading) return;` 守卫放在四个入口上
4. **阅读器只有一个 `bindSheet` 宿主** + `ReaderSheetMode` 枚举。**一个组件上挂三个 `.bindSheet()` 会互相打架**（存在感追踪一个绑定、内容追踪最后重跑的那个 → 点「笔记」弹出「目录」）
5. **Reader Kit 没有内容内缩机制**：`ReaderSetting` 恰恰 13 个字段，**没有 padding / inset / margin / safeArea**。`setPageConfig` 是唯一的布局杠杆，只吃字体度量 + `viewPortWidth`/`viewPortHeight`
6. **Reader Kit 在日间路径应用 `themeColor` 但忽略 `fontColor`**，自己画黑字。**同图内的对照证明的**：同一标称 `#3D2B1F`，ArkUI 画的顶栏实测 `#3A2D1C`（忠实），kit 画的正文实测 `#040000`。**而 `nightMode` 是承重的**——`nightMode: false` 配 `#121212` 页面会让 kit 走日间路径画黑字 = 黑底黑字
7. **`themeColor` 只接受 6 位十六进制，不接受带 alpha 的 8 位值**（华为自己的表："对于16进制颜色值，只支持6位颜色值，不支持透明度"）。**用 8 位值时 kit 会画自己的兜底色**——这就是「护眼主题下阅读页还是白的」那个 bug 的根因
8. **阅读器没有选择 API**，所以 `SelectionMenu` 不是 Reader Kit 的功能。书签/笔记锚定 `(spineIndex, domPos)`，即**一页**
9. **页码无法显示「第 N / M 页」**：`PageDataInfo` 只有 `pageHeaderContent`/`pageFooterContent`/`startDomPos`/`endDomPos`/`state`/`resourceIndex`/`pageOffset`，**没有 seek API**（只有 `startPlay`、`flipPage(isNext: boolean)`）。所以显示「第 N 页」而不带分母
10. **`HitTestMode.Transparent` 能让覆盖层吃到点击而放过拖动**（已实测：拖动时覆盖层收到完整的 Down→Move×19→Up，kit 同时收到 `onActionStart`/`onActionEnd` 并照常翻页）。**默认的 `HitTestMode.Default` 会完全阻塞 kit 的事件收集，滑动死掉**
11. **覆盖层的点击会赢过 kit 自己的点击翻页**（手势竞技场「先满足条件者胜」）。所以三分区的左右必须**自己调 `flipPage(isNext)`** 驱动翻页
12. **kit 不保留屏幕中间区域**——中间点击、长按都是零反应（真机实测）
13. **两条浮动栏必须是「页面 `Stack` 的 `position` 定位兄弟节点」，不能是列里的 band**（r100）。分页盒子的尺寸由 `layoutWeight(1)` 决定、与任何子节点无关，所以栏的显隐**不是布局事件** → 这才是「重新分页」从根上消失的原因（第 3 条是旧结构的权宜之计）。**并且栏要画在分区「之上」**：后画的兄弟节点先被命中测试，栏用 `Default` 会挡住下面的分区，分区用 `HitTestMode.Transparent` 只会「不阻塞」，**挡不住**。栏隐藏用 `Visibility.None`（**不可命中**，代价为零），不要用 `Hidden`。
14. **顶栏材质只有一条路**：`systemMaterial` 只在 `Navigation`/`NavDestination` 标题栏或横向 `Tabs`（`barPosition: End`）的底部 TabBar 里被**服务**，别处会被接受但静默丢弃（`Material inactive: out of scope`）。`uiMaterial.ImmersiveMaterial` 与 `NavigationTitleOptions.systemMaterial` 都是 `@since 26.0.0` → **必须运行时守卫**（本项目的 `canApplyImmersiveMaterial()`，读 `deviceInfo.sdkApiVersion`），API-24 设备降级为不透明页面色栏。**`Navigation` 没有 `barStyle` 属性**（只在 `NavigationTitleOptions` 里）；它默认扩展安全区，与 `position` 同设时**先 position 后 expand**，所以浮层要显式 `expandSafeArea([], [])`。
15. **待办（不是本轮）**：用户提过让 sheet 从底栏顶到顶栏（整高 sheet）——**它取决于两条栏最终落在哪里，所以明确放到后面**；本轮没有实现，也没有为它留下任何半成品。

---

## 7. 已知陷阱与它们的根因

| 现象 | 根因 | 修法 |
|---|---|---|
| 阅读位置从不保存 | **死锁**，不是竞态：`updateReadingPosition` 在写事务里调 `getDeviceId()`，后者冷缓存时排到自己后面 | `queueBusy` 重入守卫 + 把 `getDeviceId` 提到事务外 |
| 点书签跳到存储位置而不是书签位置 | `navigateToAnnotation` 先设了 `readerPosition`，`openReader` 又重新解析了一遍 | 加显式的 `annotationLocator?` 参数 |
| 「目录」点了没反应 | 一个组件上三个 `.bindSheet()` 冲突 | 单一宿主 + `ReaderSheetMode` 枚举 |
| v1 完整下载静默失败 18 次 | ① `listDir` 对集合发不带尾斜杠的 PROPFIND → Apache 301 → 跟随请求的 body 不是 multistatus；② 全新安装时**本地目标目录不存在** | ① `toCollectionRequestPath` 归一化；② 传输执行器里 `ensureParentOf`；并把错误从 `[network]` 改判为 `[FILE]` |
| 下载成功了但书显示「未下载」 | **v2 没有「把下载标记为本地」的写入者**（我原来的 `file_path` 假设被真机证伪） | 在共享执行器上修 |
| `保存凭据失败：code 201` | `Tag.IS_PERSISTENT` 需要 `ohos.permission.STORE_PERSISTENT_DATA` | 去掉那个 tag |
| 底部页签栏不悬浮 | 必须**四个条件同时满足**：`barFloatingStyle` + `barOverlap(true)` + `vertical(false)` + `barPosition(BarPosition.End)` | 而且 `barSideMargin`/`barBottomMargin` **必须是带单位的字符串**（`'16vp'`），否则 HDS 静默丢弃（`ParseProp failed parse property barSideMargin`） |
| 页签图标不渲染 | 缺 `import { SymbolGlyphModifier } from '@kit.ArkUI'` | 补 import |
| 底部黑带 | **两次误诊**。像素采样证明是 `#121212`（暗色主题底色）；根因是系统色彩模式和应用主题不一致 | `applySystemAppearance()` 里调 `setColorMode` |
| 桌面标签仍显示 "InkBoat" | `resources/zh_CN/`、`en_US/` 会覆盖 `base/` | 两处都要改 |
| `systemMaterial` 加在 Menu 上没反应 | 框架日志 `Material inactive: out of scope`——**两个不同的 API**：通用的 `CommonMethod.systemMaterial`（运行时受限）vs **`ContextMenuOptions.systemMaterial`**（`MenuOptions` 继承它） | 移到 options 对象里 |
| 半模态顶部的横条 + 背景不统一 | ① `.bindSheet` 没设 `backgroundColor`，`BindOptions.backgroundColor` **默认 `Color.White`**；② **`dragBar` 默认 true**，平台拖拽胶囊画在容器背景上、位于内容之上的一条带里 | `backgroundColor: this.sheetCard()` + `dragBar: false` + `showClose: false` |
| `SheetSize.MEDIUM` 不是「一半」 | **它是 60%**（参考文档 + `mediumPercent_ = 0.6` 两处独立来源）。`common.d.ts` 里那句 "half the screen height" 是 API 10 时代的陈旧注释 | 要字面一半用 `height: '50%'`（基准是 `窗口高 − sheet 顶部安全区`） |
| `detents` 和 `dragBar: false` 冲突？ | **不冲突**——拖拽条会被显式隐藏。**真正的理由**：设了 `detents` 后 `height` 被忽略、面板可跟手拖离该高度 | 要固定高度就不要 `detents` |

---

## 8. 架构与不变量

### 同步

- **v1 引擎「只有元数据」的正确形式（r116 修正；这里原来的两个说法都是错的，而且已经误导过一轮）**
  - **`/readany/data` 在 `SyncV1.ets` 里不是 0 次，是 4 次**，分布在 **2 行**上：`:1755` 一行 3 次
    （`/readany/data/books/{title}-{id}/`、`/readany/data/file`、`/readany/data/cover`），`:1759` 一行 1 次。
    **两行都在同一个注释块内**，而 `:1759` 那句本身写的就是「这里没有 `/readany/data` 路径可审计，因为没有」。
    （按**行**数是 2，按**出现次数**是 4 —— 引用时必须说明是哪个口径；r116 的简报用的是行数。）
    `file-manifest` = 0、`FileStorage` = 0、`.delete(` = 0 **仍然成立**。
    **实质结论不变（这几处都是散文，没有一处在代码里），但不变量必须按出现次数准确地写** ——
    写成「出现次数都是 0」，下一轮照着数就会数出 4，然后开始怀疑整段结论。
  - **`SyncV1Engine` 的构造函数**吃**文件执行器**：`SyncV1.ets:1725` 声明
    `private readonly files: V1FileRunner | undefined`，`:1733` 是构造函数的**第 6 个参数** `files?: V1FileRunner`，
    `:1740` 赋值，`:2051` 判空，`:2058` 调 `this.files.runFilePhase(...)`；生产路径
    `SyncService.ets:676-678` 就是 `new SyncV1Engine(client, this.config, this.db, undefined, undefined, files, …)`，
    传的正是 `V1FilePhase`。**正确且仍然成立的说法**：**引擎只通过 `V1FileRunner` 看到文件层，而那个接口
    只有一个方法、没有 delete / move / list**（`SyncV1.ets:1761-1764` 自己就这么写），所以 v1.3.6 的
    `cleanupRemoteOrphans`（要 listing + DELETE）在这个接口上根本表达不出来。「只有元数据」对
    **`SyncV1.ets` 自己的代码**成立，不是对引擎的对象图成立。
- **`sync_version` 不是同步判据（r116 实测记录，r121 更正引用，别再有下一轮假设它有作用）**：v1 的 5 张表**全部**以
  **`updated_at`** 比较（`SyncV1.ets:158-167` 每张表都是 `timestampCol: 'updated_at'`）；**真正的比较不在 `SyncV1.ets` 里，而在 `ShouldApply.ets`**——记录是 `shouldApplyRemoteRecord` 的 `:83-96`（`remoteTs > local.timestamp` 才应用），墓碑是 `shouldApplyTombstone` 的 `:111-116`（`deletedAt >= localUpdatedAt`）。（r121 更正：原来写的「判定在 `SyncV1.ets:1007` 与 `:54-55`」是错的——`:1007` 是 `overlayTombstones` 里的 `else if (deletedAt > existing.timestamp)`，它把本地的比较值抬到本地墓碑的高度，**不是合并谓词**；`:54-55` 是**注释里的散文**，不是代码。）
  `SyncEngine.ets` 里 `sync_version` **从不被比较**，所以它不影响合并——**但它并不是「从不被读」**（r121 更正）：`Database.nextSyncVersion` 会跑 `SELECT MAX(sync_version)`（`Database.ets:150`），`Records.ets:365` 也读它一列。它只被写入与自增，**没有任何地方拿它做判定**（`:326/:329/:333` 用 `nextSyncVersion('books')` 生成新值写进去）。而 `SyncEngine.ets:131-132` 那个
  `maxSyncVersion` 字段（注释写着「Highest local `sync_version`」）在 `:1068-1077` 是拿 **`updatedAt`**
  逐个 `Math.max` 出来的，`:1088` 塞进返回对象，**全树没有任何读者** —— **死代码，而且它的注释与它
  实际累加的东西并不一致**。记在这里，免得下一轮以为它影响合并。
- **自动同步在 v1 服务器上是设计上的 no-op（r121 新增）**：`SyncService.autoSyncGate()`（`SyncService.ets:775-785`）对 `SyncProtocol.V1` 返回一句拒绝文案，`Index.autoSyncOnStartup`（`Index.ets:2274-2278`）把它写进状态行后直接 `return`——**所以「打开 app 自动同步」对着 v1 服务器永远同步不了任何东西，两个方向都不行**。这是刻意的（启动不是替用户决定「可以删行」的时机）。**这也是用户报「同步有问题」、而服务器日志里一条请求都没有的最可能原因**——先看同步页那行字。
- **拉取是无条件且全量的（r121 新增）**：每一次 pass 都把**每一个对端**的完整快照重读一遍（`SyncV1.ets:2016-2040` 逐个设备 `loadSnapshot(device.path)`）——**没有 `since`、没有 ETag、没有「它变了没有」的判断**。所以 1 MB 的快照每点一次就重新下载、重新应用一次。反过来，上传的载荷永远是 `since: 0` 的全量（`SyncV1.ets:2123`/`:2130`），`pushOwnSnapshot` 里那个 `lastSync` 增量只用来**数变更**（`:2109-2111`）——所以「要不要推」是一个**省不省事**的决定，**永远不是内容决定**：跳过一次推送只会让发布晚一点，**不可能少掉任何一行**。
- **文件层在 `V1FilePhase.ets`**，藏在一个只有单一方法的 `V1FileRunner` 接口后面，**该接口没有 delete / move / list**
- **`V1_SYNC_TABLES` 只有 5 张表**：`book_groups`、`books`、`highlights`、`notes`、`bookmarks`
- **ReadAny 的 v1 同步 11 张表**：上列 5 张 + `threads`、`messages`、`skills`、`tags`、`book_tags`、**`reading_sessions`**
- **快照里「表为空就省略该表」是安全的**——对端不会因为「我的库里没有某张表」而删东西。**所以缺 6 张表不会造成数据损坏。**（r121 补机制：接收端遍历的是**它自己的**表清单，缺键就 `continue`——`ReadAny/packages/core/src/sync/simple-sync.ts:310-313` 的 `if (!tableData) continue;`；发送端也只在 `records.length > 0 || deletedIds.length > 0` 时才写这张表——`:282-284`。**正向判别器**：一张**零删除**的表却仍然带着 `deletedTimestamps: {}`，只可能是 ReadAny 写的——我们的 `payloadToWire`（`SyncV1.ets:1626-1639`）**只在 `deletedIds` 非空时**才写 `deletedTimestamps`。**服务器上唯一的那个设备文件就是这样判定为桌面端产物的。**）
- **「阅读统计」是同步的**（`reading_sessions`），字段 `id, book_id, started_at, ended_at, total_active_time, pages_read, characters_read, state, updated_at, sync_version, last_modified_by`。**但我们没有这张表**，所以：手机上的阅读不会产生会话记录、桌面端的统计不含手机时间、桌面端已有的会话也不会同步下来。**实现它需要：加表 + 记录会话（「活跃时长」的判定才是难点）+ 加入 payload。好处是手机的阅读会同步回桌面。**（用户暂时搁置）

### 数据层

- **书 id 是每次导入新生成的随机 UUID，没有去重**——所以重新导入会造一行新记录，**阅读记录不会跟着走**。ReadAny 的「回到那台设备重新同步（重新上传）」能保住记录，「在此处重新导入」不能。**用户裁定：这个逻辑跟随 ReadAny 的行为，以后再议。**
- **删除语义跟随 ReadAny**：点「删除」弹出模态确认，**复选框默认勾选**（`preserveData` = 软删除，也是默认）；软删 = `deleted_at` + 向量重置、行保留；硬删 = 标注墓碑 + 删除。**文案复制自 ReadAny 的 zh bundle**（`书籍文件将从书架移除。` / `重新导入同一本书时可恢复`）
- **我们的实现刻意不复制 ReadAny 不安全的顺序**：ReadAny 对数据库写入是 fire-and-forget 且独立 unlink；**我们先 await 写入、成功后才删本地文件，写入失败则书保持完好**
- **只有 `txt` 和 `umd` 会转 EPUB**（只存在两个转换器）；其他 9 种支持格式原样存储上传
- **`format='txt'` 配 `.epub` 文件是刻意的桌面端合约**——**`format` 绝不能盖过已知的真实扩展名**

### 主题

- **两套主题已被统一**：`themeMode`（应用主题，`Index.ets`）→ `paletteFor(mode)` → **`readerAppearance(mode)`**（`Theme.ets`）**一次调用同时给出背景和文字**——**所以「护眼底 + 亮色字」在结构上无法表达**
- **阅读器自己不再有主题字段**（`themeColor`/`fontColor`/`nightMode` 已从 `ReaderSettings` 移除），**`loadSettings` 会一次性清除陈旧 blob**（`RETIRED_SETTINGS_KEYS`）——**所以已有 `nightMode: true` 的旧安装不会继续白底**
- 三个主题的阅读页：护眼 `#F0E6D2`/`#3D2B1F`、暗色 `#121212`/`#F5F5F5`、亮色 `#F0F0EC`/`#090909`
- **导航页签栏的悬浮样式是全应用唯一真的渲染出材质的地方**
- **`module.json5` 刻意不设** `ohos.arkui.UIMaterial.state` **metadata**（组件级覆盖应用级；设 `enable` 会自动材质化 13 个组件类型，包括阅读器的 `bindSheet`）。需要时的确切语法：`"metadata": [{ "name": "ohos.arkui.UIMaterial.state", "value": "enable" }]`（仅 entry 模块）

### 其他刻意不采用的（已记录，不是藏起来）

- 旧的按设备快照导入
- 文本范围标注（Reader Kit 没有选择 API）
- 远端文件删除
- `tags`/`book_tags` 资料表
- 定时后台同步
- `umd` 转换（拒绝实现，不是未实现）
- 沉浸光感档位选择器（**不必要**——系统提供三档并自动映射）

### 已披露但未修的问题

- **部分文件落盘**：ReadAny 的 `storage.move` 是 `copyFile` 再 `unlink`；中途失败会在目标留下截断的文件，下一轮会把它上传出去。**已报告，未修。**
- **行级歧义（r122：v1 已解决后果，v2 仍未；限制精确如下）**：一个较旧的鸿蒙端 `current_spine`/`current_dom_pos` 组合会压过较新的桌面端 `current_cfi`，因为前者「看起来可用」。**r122 在 v1 的 apply 路径上把它解决了**：当一条 `books` 行赢下行级 LWW 并被真正写入后，`PositionWriteThroughWriter`（`data/src/main/ets/PositionWriteThrough.ets`）把本地 `sync_metadata` 位置缓存与该行携带的位置对齐 —— 行有可用 `current_spine`/`current_dom_pos` 对 ⇒ 写成该位置（`fraction = row.progress`）；没有可用对但有 `current_cfi` ⇒ **清空缓存**，于是 `resolveOpenPosition` 落到行上、阅读器开到 CFI 指的那一章；两者都没有 ⇒ 不动缓存；**输掉的行永远不会触达这里**（引擎只在 `shouldApplyRemoteRecord` 为真后调 `upsert`）。**仍然没有、也不需要「按列写入时间」**：用的是已经做出的行级胜负判定。**剩余限制两条**：① **v2 没修** —— v2 通过 `Books.applyRemoteBook` 应用一本书，是另一条合并路径，同样的矛盾在 v2 服务器上仍然存在；② 赢的桌面行只有 CFI 时**章内页码仍不可恢复**（Reader Kit 的 `domPos` 无语法），清空缓存只是让阅读器开到 `book.currentCfi` 那一章。
- **同步原子性**：`writeTransaction` 是队列串行化 + 重试，**不是真正的 SQLite 事务**（`beginTransaction`/`commit`/`rollBack` 零匹配）。ReadAny 也刻意如此。需要评估 `relationalStore.createTransaction()`（API 14+）之后才能动所有写入路径。
- **`domPos` 抽样**：设备日志显示 `startDomPos` 是结构化格式（`"0#0;@;0"`、`"8=0#12;@;0"`）。精确的跨端章内恢复也许可能，**但那是未文档化的内部格式**；需要采样收集和成本/收益判断。
- **`navigateToAnnotation` 的遗留**、`closeReader()` 的三个未 await 调用点（已修为 `void`）

### 阅读器翻页今天不打任何日志

**这是一个真实的可观测性缺口**：曾经四次预检（含两次翻页）里应用自己的日志是零行。**排查阅读器问题时记得这一点。**

---

## 9. 进行中的工作

### r124：把上游参照实现固定到 `v1.3.6`（外部检出；本仓库只有 `AGENTS.md` 改动）

**用户要求**：「在 `D:\Code\ReadAny` 把 codedogQBY/ReadAny 拉下来」「定到 v1.3.6，之后的代码不要」。

**做了什么**（全部在 `D:\Code\ReadAny`）：经 SOCKS 代理克隆 → `checkout -B pinned-v1.3.6 v1.3.6` → 删 `main`、删 **98 个** `refs/remotes/origin/*`、收窄 fetch refspec → `reflog expire` + `gc --prune=now`（unreachable 提交 **0**，`.git` 54.4 → 47.6 MB）。终态与恢复办法见 **§12.8**。

**两条必须记住的事实**：① **v2 协议不在 v1.3.6 里**（`per-book-sync.ts` 是 main 独有，main 领先 77 个提交）；② **本文档旧的行号引用是 main 的**——`simple-sync.ts:396-418` 在 v1.3.6 里实际是 **:381 / :393**。详见 §1 的「参照实现的版本口径」与 §2 的就地标注。

**没有动**：本仓库任何源码、`README.md`、`LICENSE`/`NOTICE`；没有构建、没有安装。审计基线**仍不可测**（`tools/` 不在本仓库）。

### r123：仓库布局统一（**仅文档，无代码改动**）

**用户要求**：「修改 AGENTS.md 里的仓库布局，和当前的工作目录统一」。

**实测事实（不是推断）**：
- 工作目录 `D:\Code\ReadAny-ohos` **本身就是鸿蒙工程根**：`build-profile.json5`、`build.bat`、`AppScope/`、`entry/`、`core/`、`data/`、`sync/` 全在最外层，**没有 `harmony/` 子目录**（`D:\Code\InkBoat` 在本机根本不存在）。
- 仓库根**就是** git 仓库（`D:\Code\ReadAny-ohos\.git`），`origin` 是 **HTTPS**，不是 SSH。
- 本机**没有**检出上游 ReadAny；`tools/`、`.diag/`、`docs/` **都不在本仓库** —— 所以 §3.2 的 30 工具审计、`.diag/*.mjs` 变异脚本在这里**跑不了**。

**改了什么**：§1 布局块重写 + 新增「路径口径」说明；硬约束 #1/#2/#7；§3.1/§3.2 命令；§4.2 的提交位置与 ArkTS 文档引用；§12.1 表格（`origin`、仓库本体）；§12.2/§12.3/§12.4/§12.6/§12.7 里零散的 `harmony/` 前缀；以及全部产物路径 `harmony/entry/build/…` → `entry/build/…`（6 处）。**历史轮次正文保留原样**，由 §1 的「路径口径」统一解释。

**没有动**：任何源码、`README.md`、`LICENSE`/`NOTICE`；没有构建、没有安装、没有推送。**审计基线本轮不可测**（`tools/` 不在本仓库），所以不引用任何数字。

### r122：拉取**赢下的那一行**把位置写进本地缓存（修「同步成功了，点进去还是旧进度」）+ 密码**留空即沿用**（修「每次改目录都要重输密码」）

两个独立的 bug，根因都已由上一轮定死，本轮只实现。**没有改线格式、没有改 `V1_SYNC_TABLES`、没有改墓碑处理、没有设 `forceApply`、没有动 `ReaderView.ets`。**

#### Bug 1 — 用户原话

> 「**牧神记的阅读进度是80%，我手机上的阅读进度在同步之前是70%，同步成功后显示的是80%，但是点进去还是在70%的进度那里，进去再出来进度又变回70%了。**」

**① 证据（服务器两设备快照，只读复核）**：`/srv/webdav/readany-sync-test/sync/` 里同一个 `id = d54eee47-eab6-4150-964b-4a177f2ad108` 的行——

| 字段 | 桌面 `c890b8f3…` | 手机 `4aeac148…`（同步后） |
|---|---|---|
| `progress` | 0.8024562 | 0.8024562 ✅ 已拉取 |
| `current_cfi` | `epubcfi(/6/3008!/4,/80,/104/1:45)` | 同 ✅ 已拉取 |
| `current_spine` | **不存在（桌面 `books` 没有这列）** | **1278** ← 手机自己的 |
| `current_dom_pos` | **不存在** | **`0=0#0;@;0`** ← 手机自己的 |
| `last_modified_by` | c890b8f3 | c890b8f3 |

所以这一行**同时持有两个矛盾的位置**：新 CFI（80%）+ 旧 spine/domPos 对（70%）。根因是 upsert 的「**payload 里没有的列不动**」规则（`SyncV1.ets:1017-1054`）——**这条规则没有被削弱**，本轮修的是它的后果。

**② 为什么阅读器取了旧的那个**：`ReaderStore.resolveOpenPosition`（`:227`）**本地缓存优先**，行上的列只是兜底。于是 ①拉取→`progress` 0.80 ②打开→解析出旧的 70% ③关闭→`persistPosition` 把 70% 写回行、`updated_at` 变新 ④下次同步→手机的 70% 变成最新的 → **反向摧毁桌面的 80%**。第 ④ 步才是数据丢失。

**③ 规则（三个分支，一分不多）** —— 当一条 `books` 行**赢了行级 LWW 且被真正写入**后，把本地 `sync_metadata` 位置缓存与该行携带的位置对齐：

| 赢的行携带 | 对缓存做什么 | 为什么 |
|---|---|---|
| 可用的 `current_spine`/`current_dom_pos` 对（`hasSyncedPositionColumns`，即 `domPos.length > 0 \|\| spine > 0`） | **写成该位置**（`fraction = row.progress`） | 对端确实有更精确的阅读器坐标 |
| 没有可用对，但有非空 `current_cfi` | **清空缓存** | 于是 `resolveOpenPosition` 落到行上、阅读器开到 `book.currentCfi` 指的那一章（这正是全新安装的行为）——**牧神记就是这一支** |
| 两者都没有 | **不动缓存** | 没有位置的对端对这台设备的位置什么也没说 |

**输掉的行永远不会触达**：`SyncV1` 只在 `shouldApplyRemoteRecord` 为真之后才调 `writer.upsert`，输的分支 `continue`。**这是结构性质，不是这里再判一次**。**没有引入任何新的时间戳，也没有比较时间戳**：用的是**已经做出的行级胜负**。`books.updated_at` 不是位置时间戳（每次无关编辑、每次拉取都会 bump），`last_opened_at` 也不是——这两条论证**原样保留**。

**④ 接缝：`record writer` 装饰器，而不是往 `SyncV1` 里挂钩子。** 新文件 `data/src/main/ets/PositionWriteThrough.ets` 里 `PositionWriteThroughWriter implements V1RecordWriter`，把真 writer 包起来；`upsert` 是**唯一**有自己行为的方法（其余 4 个方法原样转发：`columnsOf`/`loadStates`/`remove`/`rememberTombstone`）。生产接线在 `SyncService.ensureV1Engine`：`new SyncV1Engine(client, this.config, this.db, writer, undefined, files)` 的第 4 个参数从 `undefined` 换成 `new PositionWriteThroughWriter(new RdbRecordWriter(this.db), this.db)`。

- **为什么这里**：`SyncV1` 是表通用的，它唯一需要告诉 writer 的事实就是「这一行赢了，写它」；把「刚写下的那一行」同步到阅读器缓存是**阅读器的事**，用同一个端口表达即可。所以 **`SyncV1.ets` 一行未改**（审计断言它**不含** `current_spine`/`current_dom_pos`/`current_cfi`/`PositionWriteThrough`，全文只有 **1 处** `writer.upsert(` 且位置在 LWW 判定之后）。
- **行先写、缓存后跟**：`upsert` 里 `await this.inner.upsert(...)` 在 `reconcilePosition` 之前。否则「缓存成功、行写失败」会让设备恢复到一个**没有任何行携带的**位置。
- **缓存失败只记日志，不重抛**：`SyncV1` 会把抛异常的 `upsert` 记成 **skipped**，于是**已经应用**的行会在每一轮都被报成跳过，真正的原因反而永远看不到。
- **只对 `books`**：`if (table !== 'books') { return; }`。

**⑤ 写回侧已从代码确认**：`Index.openReader` → `resolveOpenPosition` → `ReaderView` 首屏 `onPositionChanged`（`lastReportedSpine` 初值 `-1`，**首屏一定上报**）→ 节流 flush → `persistPosition`（先写本地缓存，再 `updateReadingPosition`）。所以**关闭时写的就是解析出来的那个位置**；修复后它解析成 80%，写回也是 80%。**仍然会写「旧」位置的只有一处**：`flushPendingPosition` 的 `committedPosition` 兜底（上一轮会话的最后位置）——同一本书时它本来就是对的，而且阅读器占屏期间不可能有拉取，所以本轮不动它。

**⑥ 明确不覆盖**：**v2 路径没修**。v2 通过 `Books.applyRemoteBook` 应用一本书，是另一条合并路径，同样的矛盾在 v2 服务器上仍然存在（已写进 §8 的「行级歧义」）。

#### Bug 2 — 用户原话

> 「**然后我想保存同步界面里的密码，不然每次改目录都要重新输密码。**」

**① 根因（已复核）**：`SyncSettingsPage.ets:58` 的 `@State private password: string = ''` 起始为空且**从不从凭据库填充**；`:183` 把 `this.password` 交给 `onSave`；`Index.saveConnection:1815` → `SyncService.saveConnection:462` **无条件** `await this.credentials.setWebDavPassword(password)`，而那个 setter 对空串的行为是**删除**（`CredentialStore.ets:251-255`）。于是「改远程目录 → 字段是空的 → 保存 → 凭据被删」→ `configured`（`:475-476` 要求 `hasWebDavPassword()`）变 false → 下次同步认证不了。旧文档那句「空密码清空凭据，这样『清空字段并保存』就符合用户预期」对**主流流程**是错的。

**② 新契约（`saveConnection`，文档已重写、旧段落已删除并被审计断言不存在）**：
- **空 → 保留**已有的凭据（实现：`if (password.length > 0) { await this.credentials.setWebDavPassword(password); }`）；
- **非空 → 覆盖**；
- **清除变成显式动作**：新增 `SyncService.clearWebDavPassword()`（清凭据 + `dropEngines()` + 用 `hasWebDavPassword()` 重算 `configured` + emit）。**`dropEngines` 是必须的**：共享 `client` 是用被删掉的密码建的，留着它会继续用用户刚删除的凭据认证。`clearConfiguration()` **照旧**清密码。
- **调用者已核**：全树 `saveConnection(` 恰好 **3 处** —— `SyncService` 的声明、`Index` 的私有包装声明、`Index` 里 `sync().saveConnection(...)` 那一处调用（审计断言这个数）。**没有任何调用者依赖「空即清空」**。

**③ 页面**：新增 `@Prop hasStoredPassword: boolean`（**由 shell 传入，页面不碰服务单例**，与 `config`/`palette` 同一形状）+ `onClearPassword` 回调。
- **placeholder 条件化**：有凭据 → `已保存 · 留空则不修改`；没有 → `密码`。密码标签下的提示也分叉（有凭据时「已保存…留空表示沿用」）。
- **显式清除控件**：仅当 `hasStoredPassword` 时出现的小号次级按钮「清除已保存的密码」，**透明填充（显式 `Color.Transparent`）+ `$r('sys.color.warning')` 字形**，走 `onClearPassword` → `Index.clearStoredPassword` → `sync().clearWebDavPassword()` → `applyConfig()` + `refreshCredentialState()`。
- **确认**：加了，用 **`UIContext.showAlertDialog`**（**不是**被弃用的全局 `AlertDialog.show`；编译器每次构建都会警告它）。它是**平台对话框**，浮在页面上而不是排在页面里，**不扰动布局**，所以满足「不要用会打乱布局的模态」。
- **没有预填真实密码（刻意选择）**：把真 secret 读进 `@State` 会让它在 UI 状态里，而且「空 = 沿用」在字段已经被填满的情况下无法表达。**字段仍然看起来是空的，这就是信号**（placeholder 承担说明）。保存成功后字段清空，于是占位符/说明文案重新可见。
- `InputType.Password` 与 `.onChange` 行为**未动**。
- **页面文案纠正**：保存后不再说「注意密码为空，同步前需要补填」（那是旧契约），改成「密码留空，沿用已保存的密码」/「尚未保存密码，同步前需要填写」两种。

**④ 反转的文档/契约（逐条）**：
1. `SyncService.saveConnection` 的「**空密码清空凭据**」段落**删除**并换成新契约（审计断言旧句不存在、新句存在）。
2. `ReaderStore.resolveOpenPosition` 的「**已经在本机读过的书永远保留本机位置，即使对端读得更远**」不再无条件成立 → 改成「**只到下一次拉取应用了一条获胜行为止**」，并写明「本机位置**绝不会被输掉的行摧毁**」；`updated_at`/`last_opened_at` 的论证**原样保留**（审计断言它仍在）。
3. 同步页保存成功文案（见上）。
4. §8「行级歧义」从「未解问题」改成「**部分解决 + 两条精确限制**」。

#### 没有动的东西

`ReaderView.ets` **一个字节未改**（所以 strip 探针 9 个锚点行号**完全不变**）；`Rdb.ets` 的 `queueBusy`、三个破坏性同步操作、墓碑上界、`V1_SYNC_TABLES`、线格式、`forceApply`、r118–r121 的书架头部/材质/`Scroller.currentOffset()`/`tempo`；同步页的单一父级水平内缩（r116，**这条审计本轮抓到过一次**：我最初给清除按钮写了 `padding({ left, right })`，`verify-reader-chrome` 立刻失败，改成不写内边距、靠胶囊自带的内边距，**没有削弱那条断言**）。**没有新增任何十六进制颜色字面量**。

#### 审计

**30 工具 / 3848 项 / 3848 通过 / 0 失败**（基线 **3744** → 净 **+104**）。逐工具：**`verify-reading-position` 274 → 345（+71）**、**`verify-sync-modes` 87 → 120（+33）**、`verify-book-menu` **271 → 271**（`BUILD_STAMP` 钉子从 r120 改到 r122，计数不变）、**其余 27 个工具逐条相同**。失败集合 **∅**。裸 `Select-String 'passed'` 仍是 **34** 行。

- **反转/改写的断言**：`BUILD_STAMP` 钉子 → r122 的 tag；`verify-reading-position` 的 `buildSeedApi` **必须**找到新的 `hasSyncedPositionColumns`（否则整个 seeded 段会抛错），所以那条提取检查**变强**（现在要求两个定义都在、且 `hasSyncedPosition` 显式转发给它 —— 断言「一份定义」）。
- **新增的断言**：三分支规则**被当成真实函数执行**（`pulledPositionAction` + 真实的 `hasSyncedPositionColumns`，含牧神记那一行 `epubcfi(/6/3008!/4,/80,/104/1:45)` → CLEAR、以及「有对就 SET，即使同时有 CFI」）；三个判定值互不相同；「行先写、缓存后跟」；「只对 books」；「缓存失败不逃出 upsert」；「恰好一个方法调用 reconcile」；4 个转发方法；装饰器不碰 SQL（不用 `rdbHandle`）；生产接线两处；**引擎不含任何位置列**；**全文只有 1 处 `writer.upsert(` 且在 LWW 判定之后**；输的分支 `continue`；端口仍可选；注释的新限定语与新安全半句；**reconcile 的代码里不出现 `updated_at`/`last_opened_at`**（**按去注释源码断言**，因为散文里必须允许提到它们）。
- 凭据侧：新契约句存在/旧句不存在；写入被非空守卫；`saveConnection` 里恰好一次凭据写；连接先存；显式清方法存在且清凭据/dropEngines/重算 configured；`clearConfiguration` 仍清密码；`saveConnection` 全树恰好 3 处；页面不直接碰服务；`@Prop` 存在且被 shell 传入；placeholder 两态；字段仍空且仍是 `Password`；**页面不出现 `getWebDavPassword`**；`onChange` 未变；清除控件存在且**仅在有凭据时渲染**；确认走 `UIContext.showAlertDialog` 而非全局 `AlertDialog.show`；shell 保存后/清除后都刷新凭据状态（**按方法体切片断序**）。
- **`.diag/r122-mutate.mjs`：21/21 全抓、2/2 controls 全绿、0 条 NOT APPLIED、6 个源文件 sha256 逐字节还原。** 变异覆盖：两个分支互换、CFI 分支删除（复现用户报的 bug）、无位置也清缓存、缓存先于行、books 门删除、异常逃出 upsert、谓词缺 domPos 半、LWW 门绕过、引擎学列、装饰器建了没传、注释失去限定、空密码直达凭据库、placeholder 退化、清除按钮常驻、预填 secret、弃用对话框回潮、旧保存文案回潮、清除不清引擎、`configured` 直接置 true、保存后/清除后不刷新。**两条 control**：把 `current_spine`/`updated_at` 写进**注释**、把注释改写——都必须保持全绿（证明去注释切片真的有效）。

#### 产物

`entry/build/default/outputs/default/entry-default-unsigned.hap`，**1,948,303 字节**，sha256 **`fbb666145e8f340f3163941edb0dbc1cfd691fa298c54beb4d2a291482f1c382`**（**clean 构建后磁盘上那个文件**；按 §3.1，增量构建的产物只差 `ets/modules.abc` 与 `ets/sourceMaps.map`，所以 hash 标识的是这一个文件而不是可复现构建），未签名（`Will skip sign 'hos_hap'`），由用户手动安装。**增量构建与 `clean` 后构建都 `BUILD SUCCESSFUL`。**

#### 未验（不许当成已验）

**本轮设备不在**：`hdc list targets -v` 返回 `[Empty]`，所以**没有 `uitest dumpLayout`、没有注入任何手势、没有装机观测**。修复本身完全未上机。必须手跑：
- 手机上打开牧神记 → **80%**（不是 70%）；退出再进 → 仍 80%；书架仍 80%；
- **再同步一次，确认桌面端仍是 80%**（没有被反向覆盖）——这是 bug 1 的另一半；
- 改远程目录 → 保存 → **下一次同步仍能认证**，不需要重输密码；
- 用「清除已保存的密码」→ 确认 → 下一次同步**认证失败/显示未配置**。
- 未观测：`UIContext.showAlertDialog` 在三个主题下的外观、清除按钮在长文案下是否换行、以及 `hasStoredPassword` 在冷启动时是否已经在首帧正确（`refreshCredentialState` 在 `bootstrap` 里 await，但 `@Prop` 初值是 `false`，所以**极短的一帧**可能显示「无凭据」的 placeholder）。
- **v2 服务器上的 bug 1 未修**（见 §8）。

### r121：文档纠错（6 处）与敏感信息打码（**无代码改动**）

**只改 `AGENTS.md`，一行代码没动、没有构建、没有提交、没有推送**（由父代理验证与提交）。本仓库（当时还是 `harmony/`）与另检出的 `ReadAny/` 的 `git status --porcelain` 都是空。

**① 打码（目标仓库是 public，这是硬需求）**：服务器地址 → `<vps-ip>`、三处测试设备地址 → `<device-ip>`、随设备地址出现的 hdc 端口 → `<hdc-port>`、三处联系方式邮箱 → `<github-email>`、GitHub 数字 user id → `<github-user-id>`。**保留 `hkb65536`**（公开仓库 owner，出现在远端 URL 与提交身份里）、SSH 别名 `2C2G`、`/srv/webdav/…` 与 `D:\Code\ReadAny-ohos` 路径。**在「维护规则」后加了一条「打码约定」**：需要真实值时直接问用户，不许翻 git 历史、不许从别的文件推断、不许猜。**终稿扫描：五个原串各 0 处**——本段刻意不写出原串，写出来就等于没打码。

**② 六处事实纠错**（保留原文、就地标注「r121 更正」）：
1. §2 接收端守卫：原来那句只描述 ReadAny。现在分开写——**ReadAny 只有一个 `deletedAt > 0` 的时间戳比较**（`simple-sync.ts:396-418`，`deletedAt <= 0` 时整段跳过 ⇒ 无条件 `DELETE`）；**我们有四道闸门**（`SyncV1.ets:1345/1356/1368/1383`），**`deletedAt <= 0` 的 DELETE 路径不可达**。结论与铁律不变，**时间戳闸门 3 对 1（多三道）**，第四道（活跃行）两边共有。
2. §8 `sync_version` 的引用：`SyncV1.ets:1007` 是 `overlayTombstones` 的「抬高本地比较值」，`:54-55` 是**注释散文**；**真正的比较在 `ShouldApply.ets:83-96`（记录）与 `:111-116`（墓碑，`deletedAt >= localUpdatedAt`）**。
3. §8 `sync_version`「只被写、从不被读」**字面为假**：`Database.ets:150` 的 `SELECT MAX(sync_version)` 与 `Records.ets:365` 都在读。**改成「从不被比较」**，结论（不影响合并）不变。
4. §8 新增两条：**自动同步在 v1 上是设计上的 no-op**（`SyncService.ets:775-785` + `Index.ets:2274-2278`）；**拉取无条件全量、上传永远 `since: 0`**（`SyncV1.ets:2016-2040` / `:2123` / `:2130`），「推不推」只是省事，不是内容判断。
5. §3.6 备份路径 `/srv/webdav/readanybak/` **已不存在（r121 实测）**，只标注、不删除。
6. §8「表为空就省略是安全的」补机制（`simple-sync.ts:310-313` 的 `if (!tableData) continue;`、`:282-284` 的空表省略）与**正向判别器**：零删除却带 `deletedTimestamps: {}` ⇒ 只可能是 ReadAny 写的（我们的 `payloadToWire` 只在 `deletedIds` 非空时才写它，`SyncV1.ets:1626-1639`）。

**③ 审计基线不变：30 工具 / 3744 项 / 3744 通过 / 0 失败**（文档改动不进审计）。

### r120：**修掉「隐藏了就回不来了」**——标题的显示侧改读**真实滚动位置**（`Scroller.currentOffset()`），并把「界面动效」的速度经 `AnimateParam.tempo` 接到收起动画上（**已完成构建与审计；根因与两个几何状态已真机实测，修复本身未装机验收**）

**用户原话**（装着 r119）：「**现在位置对了，但是我还想加过渡动画。然后隐藏的逻辑应该是往上滑动看下面的书的时候隐藏，等回到第一页的时候标题又显示回来。现在隐藏了就回不来了**」

三件事，**第三件是 bug**，第二件是它的**果**。

**① 根因（结构性，且有真机复现）**：r118/r119 把 `onDidScroll` 的**每帧增量**累加进 `ShelfPage.scrollOffsetVp`，并在 `< 0` 时清零。于是
`offset = Math.max(0, offset + delta)` —— **只增不减，是单调的**。判定式原本是
`shouldHide = !(offset <= HEADER_TITLE_SHOW_AT) && (up || this.shelfTitleHidden)`，而
**`shelfTitleHidden` 一旦为真，第二个合取项就恒为真**，所以标志只能靠第一个合取项清除 —— 也就是
**只有累加值回到 ≤ 12 才可能恢复**，而它回不去。**用户报的就是这个症状。**

**真机实测（`<device-ip>:<hdc-port>`，本轮 `Connected`，可用）**：冷启动标题**显示**（`TitleBar`
`[0,132][1320,467]`、搜索框顶边 291、渲染 12 项）；**上划一次后标题消失**
（`[0,132][1320,348]`、搜索框顶边 172、渲染 9 项）；此后**连续 5 次下滑**（其中两次大幅甩到底），
列表确实回到顶部（渲染项数回到 12）而**标题始终不回来**。这与 `AGENTS.md` 原来那条
「`EdgeEffect.Spring` 把 `offset` 带回 0」的推理**不符**：那个假设是错的，已删除。

**② 修法：位置，而不是增量之和。**
- `Scroller.currentOffset(): OffsetResult`（`scroll.d.ts:467`，**`@since 7`**）给的是**位置本身**：
  `yOffset` 单位 **vp**，顶部为 **0**。`Grid(scroller?: Scroller, layoutOptions?)` 把它作为
  **第一个位置参数**（**不是** `List` 的 `{ scroller: … }` 对象式；写成对象式会编译报
  `Argument of type '{ scroller: Scroller; }' is not assignable to parameter of type 'Scroller'`，
  **是编译器定的形**）。
- `private gridScroller: Scroller = new Scroller();` 绑定到 `Grid(this.gridScroller)`；
  **`scrollOffsetVp` 字段整体删除**（连同 `aboutToAppear` 里的清零），所以没有可失效的累加器。
- `handleGridScroll()` 不再吃参数，只当**帧时钟**；值取自 `currentOffset().yOffset` 并上报。
- 规则收进**位置的纯函数** `Index.shelfTitleShouldHide(offset)`：**`<= 12` 返回 false（显示）、
  `>= 24` 返回 true（隐藏）、带内保持**。`onShelfTitleScroll(offset)` 只做「和现状不同才应用」。
  **方向参数 `up` 被整体删除** —— 规则只依赖位置，第二个输入只会和它冲突，而且删掉之后
  「顶部一定显示标题」成了**关于函数的可断言性质**（r119 那条写法在结构上做不到）。

**③ 「过渡动画」：动画一直在，只是有一半永远看不到。** 用户说「还想加」，读作「没有」。**设备端帧突发
（`snapshot_display`，本机约 320ms/帧）证明它有**：标题暗像素 **8770（before）→ 中间帧 2229**
（部分淡出、部分位移，快照产生不出来的中间态），搜索框顶边 **291 → 169**。所以「看不到过渡」的
**主要来源就是 bug 本身** —— 一旦隐藏就再也回不来，返回那一半永远不可达。
- **保留 spring**（`curves.springMotion(HEADER_TITLE_RESPONSE, HEADER_TITLE_DAMPING)` = 0.45/0.85；
  SDK 默认是 0.55/0.825，所以它本来就略快于框架默认，不是「几乎瞬间」）。
- **新增 `AnimateParam.tempo`**（`common.d.ts:3439`，`@since 7`，默认 1.0）。理由：`duration`
  在 spring 曲线上**不生效**（`common.d.ts:3413-3415`：「curve配置 springMotion…时…不生效，动画持续时间
  由弹簧曲线自身的物理参数…决定」），所以在此之前**「界面动效」的速度设置对这个动画完全无作用** —— 它被
  钉死在弹簧自己的时长上。`tempo` 是三个参数里唯一对弹簧有效的。新增 `Motion.ets` 的
  `ANIMATION_TEMPOS = [1.35, 1.0, 0.75, 0]`（与 `ANIMATION_DURATIONS` 同一套四档）+
  `tempoForSpeedIndex()` + `MotionUtil.tempo()`；`MotionUtil.tempo()` **永不返回 0**（`tempo: 0`
  是「没有动画」，而本项目的「关闭」是「不进 `animateTo` 上下文」，两件事不同）。
- **`animateTo` 里没有 `duration`**，这条现在按**去注释**源码断言。

**④ 几何一个字都没动**（这是硬约束，也是审计在数的那组）：`138.25 / 103 vp`、
`headerBarCurrentHeight()` 单一二选一、**恰好 4 个 `headerBarCurrentHeight()` 调用点**、
材质载体读同一个表达式（不是 `'100%'`）、搜索行落在标题原框内、`Grid` **无底部 padding**、
`contentEndOffset` 调用点未碰、`titleHidden` 的读者仍是构造器里 3 + `headerBarCurrentHeight` 1。
`ReaderView.ets` **一个字节未改**。

**⑤ 审计**：30 工具 / **3744** 项 / 3744 通过 / 0 失败（基线 **3739** → 净 **+5**，**全部在
`verify-book-menu` 266 → 271**，其余 29 个工具逐条相同）。裸 `Select-String 'passed'` 仍是 **34** 行。
失败集合 **∅**。
- **改写的断言（每条都等价或更强）**：「delta 被累加」→ **「位置取自 `currentOffset()`，且方法体里
  出现 `+=` 或 `delta` 就失败」**（更强：平面否定，累加器不能在 scroller 旁边偷偷长回来）；
  「规则读累加值比两个阈值」→ **「规则是位置的纯函数，且 `up` 不出现」**（更强：少一个输入，且顶部
  性质可断言）；「累加器在 `aboutToAppear` 清零」→ **「整页不再有 `scrollOffsetVp`」**；
  「把方向和距离都上交」→ **「只上交位置，且两端按名字对上」**；`Grid` 锚点从 `Grid() {` 改为
  `Grid(this.gridScroller) {`（**必须带绑定形式**：我自己的注释里引用了声明签名，裸 `Grid(` 会先命中文案）；
  `BUILD_STAMP` 钉子从 r119 改到 r120。
- **新增的断言**：**「标题能在列表顶部回来 —— r120 修的就是这个」**（断言
  `shelfTitleShouldHide` 的 `<= SHOW_AT` 提前返回体，位置形式不是 `[\\s\\S]*?` 所以插入语句抓不到，
  已用变异验证）、`Grid` 绑定了 scroller（位置式）、整页无累加器、`tempo` 接线 + 四档表严格单调
  + `tempo()` 不返回 0、`animateTo` 里没有 `duration`。
- **`.diag/r120-mutate.mjs`：22/22 全抓、3 条 control 全绿、0 条 NOT APPLIED、4 个源文件 sha256
  逐字节还原。** 其中**专用「回不来」变异 4 条**（把提前返回改成 `return this.shelfTitleHidden`；
  加 `&& !this.shelfTitleHidden`；`return true`；把 `>= 24` 提到前面使 `<= 12` 不可达）**全部被抓**。
  锚点唯一性由 `.diag/r120-anchors.mjs` 先验（22/22 unique）。

**产物**：`entry/build/default/outputs/default/entry-default-unsigned.hap`，**1,923,493 字节**，
sha256 **`96938022230d88bdda76819ab4684b98b4bed70e0b2580a7023c0d0dc1444eb5`**，未签名
（`Will skip sign 'hos_hap'`），由用户手动安装。**增量与 `clean` 后构建都 `BUILD SUCCESSFUL`。**
本地提交 **`5cb124f`**（未推送）。

`.diag/strip-sheet-probe.mjs`：**9 个块 / 31 个标记**、`PROBE FULLY REMOVED: true`、
`chars 262340 -> 253463; lines 4726 -> 4584`，锚点 **506 / 833 / 930 / 3737 / 3771 / 3802 / 3908 /
4601 / 4625** —— **与 r116/r118/r119 记录完全一致，因为本轮同样一个字都没改 `ReaderView.ets`**。

**未验（不许当成已验）**：**修复本身没有装机观测** —— HAP 未签名，agent 装不了（§3.4 的既定流程）。
设备在本轮**可用**，用它测的是**装着的 r119**（复现 bug + 量两个几何状态 + 抓动画中间帧），
**不是**修复后的行为。必须装机核对，**两个方向、三个主题**：
- **上划 → 隐藏**：标题淡出上移的同时整块区域收起，搜索框/同步/导入上移到标题原来的框位置；
- **🔑 回到顶部 → 标题必须回来**（这就是本轮修的东西）。**列表很短**（12 本，一屏放得下 9 本），
  所以「回到第一页」很可能就是**很小的滚动量**：滑一点点就该看到标题回来；
- 带内（12 vp 以内）来回滑**什么都不动**；
- **「设置 → 动画」关闭**：收起与淡出**同一帧内瞬间完成**（不是 0 时长）；
- **速度换成「快速」和「慢速」各试一次**：收起所需时间应**看得出不同**（这是 `tempo` 那条，
  **同样未观测**）；
- 三主题下按钮无填充、材质透出、字形可读；搜索框仍在材质之上；
- 进「设置 → 同步」再返回、三个 tab 之间来回切，头部都正确。

### r119：**对 r118 的两条修正**——书架标题隐藏时**整块区域收起**（标题栏高度也随之收），两个圆形按钮改**透明 + 系统可反色图标资源**（**已完成构建与审计，未装机验收**）

**用户原话**（看着装好的 r118）：「**我现在装了 r118，这个书架标题消失和我想的不太一样，可能是我没说清。我不是只想文字消失，我是想那块区域也消失。也就是说下拉的时候搜索框、同步按钮和导入按钮要顶到现在标题的框的位置。然后两个按钮现在都是黑色的，帮我换成透明的吧，不然沉浸光感看不出来**」

两条都是**对 r118 做法的纠正，不是新功能**。r118 的两条刻意选择**都被用户推翻**，理由如下（都已落进代码注释与断言）。

**① 「下拉」的口径**：用户写的是「下拉的时候」，但上一轮他写的是「**上划的时候就隐藏**」，而 r118 的实现就是上划隐藏。**按现有的触发规则实现（上划隐藏 / 下滑或回到顶部恢复），没有改 `onDidScroll`、没有改 24/12 双阈值带、没有改 `ScrollState` 不分叉那三条**；「下拉」按笔误处理，已在报告里点明。**真正会「下拉」的东西只有回到顶部时 `EdgeEffect` 的弹簧**——它在 12 vp 带内恢复标题，这本来就是 r118 的设计。

> **⚠️ r120 已推翻本节的两条推理，读下面「② 迟滞带」与 r118 段时要带着这个更正：**
> 1. **「没有改 `onDidScroll`」这条不再成立** —— r120 把累加器整体删掉、改读
>    `Scroller.currentOffset()`，`Grid` 也绑了 `Scroller`。
> 2. **「回到顶部时 `EdgeEffect` 的弹簧会把偏移带回 12 vp 带内」是错的**（r118/r119 与 r120 的
>    初版简报都信了它）。r119/r120 的真机实测都不支持它；真正的原因是**累加器单调**，
>    与弹簧无关。**别再把这个假设当事实引用。**

**② 收起是「布局动画」，这是本轮唯一一次刻意离开「只动 opacity/translate/scale」的规矩，理由是可检验的：**

- 用户要的是**区域**消失，而**区域就是布局**：标题那一行同时是标题栏的内容，标题栏的高度就是网格向下让出的距离。所以要么改高度，要么区域留着——**没有第三条路**（负 margin / `layoutWeight` / `offset` + `clip` 都试过，见下）。
- **迟滞带让这件事从「每帧」变成「每次切换」**：判定不在页面里、也不在每帧里，而在 `Index.onShelfTitleScroll`——它拿**累加**偏移去比 24 vp（藏）和 12 vp（显），中间 12 vp 的带里状态保持不变。所以布局**只在跨越带时变一次**，带内怎么滑都不动。r118 担心的「手势过程中 reflow」是**每帧**的性质，这里没有。
- **r109 的整行 pop 不是「盒子变高」，是「有底部 padding」**：那个 `Grid` 因为 `.padding(bottom)` 而**拒绝绘制一个完全落在 padding 带里的子项**（「如果子组件完全位于padding区域内，则不会显示」），于是整行会在**一帧内整体弹入**。这个 Grid 仍然**没有底部 padding**，底部余量走的是 `contentEndOffset`（连调用点都没动），所以那条规则按自己的条款就不适用。
- **这个 Grid 的行高由列宽推导，不由网格自身高度推导**（`GridItem` → `columnsTemplate` 里的 `aspectRatio` 封面），所以盒子长高 35.25 vp 只是**多露出下一行的 35.25 vp**，不移动任何一行的上边缘——**和用户此刻正在做的「滚动 35.25 vp」是同一件事**。
- **阅读器不是这个情况**：它的重新分页来自交给 Reader Kit 的**实测分页盒**；这里没有任何东西被测量、也没有任何东西被上报。
- **动效门控照旧**：收起和淡出跑同一个 `animateTo`；「设置 → 动画」关闭时**直接赋值、不开动画上下文**（不是 `duration: 0`）。

**③ 确切的两个高度（参考机 39 vp band）**：

| 状态 | 算式 | 值 |
|---|---|---|
| 标题显示 | `topInsetVp + SPACE_S + TYPE_TITLE_LARGE×1.175 + SPACE_S + MIN_TAP_TARGET` = 39 + 8 + **35.25** + 8 + 48 | **138.25 vp** |
| 标题隐藏 | `topInsetVp + SPACE_S + MIN_TAP_TARGET + SPACE_S` = 39 + 8 + 48 + 8 | **103 vp** |

差**恰好 35.25 vp**，就是 `headerTitleHeight()` 本身；搜索框/同步/导入因此**正中标题原来那个框的位置**，而 band 仍在最上面（首行墨迹不会跑进挖孔）。r118 注释里那个「~44 vp」是它自己的估算，**真值是 35.25 vp**。

**④ 实现（`ShelfPage` 只改一处属性 + 三个 helper）**：`headerBarHeight()`（显示）/ `headerBarCollapsedHeight()`（隐藏）/ **`headerBarCurrentHeight()`（唯一的二选一）**；`Navigation.height`、`Navigation.title` 的 `height`、**以及材质载体 `Column` 的 `height`** 全部读同一个 helper（**恰好 4 个调用点，审计数这个数**）——最后一条是「**收起的 bar 不能把材质画到自己盒子外面**」的答案：载体盒子**就是**当前高度，所以材质既不会短于它承载的那一行（那会让搜索框浮在没上色的条上），也不会长过它。`headerTitle` 的高度是 `this.titleHidden ? 0 : this.headerTitleHeight()`，**`titleHidden` 全文恰好 4 个读者**（builder 里 3 个：height/opacity/translate；`headerBarCurrentHeight` 里 1 个），r118 那条「恰好 2 次」**改成「全文恰好 4 次、逐个点名」**（更强：旧的数看不见 builder 之外的读者，而新的那个恰好在外面）。
- **没有用负 margin / `layoutWeight` / `position` / `offset` + `clip`**：审计把那五个属性连同 `clip` 一起**否定**在 `headerTitle` 之外，所以机制只有「height」一种，变异测试里那条「改用负 margin」被抓。
- **没有 clip**：`Row` 默认不裁，`opacity` 与高度同一条曲线归零；加 `clip(true)` 只会在滑动中途把字切一半（审计也已否定）。

**⑤ 两个按钮：`palette.primary` 填充 → `Color.Transparent`，`primaryForeground` 字形 → `$r('sys.color.icon_primary')`。**

- **为什么「删掉 `backgroundColor`」不等于透明**：未设背景的 `Button` 用的是框架自己的按钮色，**跟随系统色彩模式**——那正好就是要除掉的那块黑圆片。所以必须**显式**写 `Color.Transparent`。变异测试里「直接删掉 `backgroundColor`」那条被抓。
- **为什么字形必须换成系统资源**：材质样式为 THIN/ULTRA_THIN 时 `fontColor` 用系统可反色资源会自动反色，而「**使用硬编码的颜色值（如 Color.White、'#FFFFFFFF'）不会触发自动反色，仅对…特殊资源（见下表1）值时生效**」。`@ohos.arkui.uiMaterial` 的**表1 · 特殊资源值对应的深浅色值**里就有 **`$r('sys.color.icon_primary')` = `#E5000000`（浅色）/ `#E5FFFFFF`（深色）**，而 `SymbolGlyph` 的 `fontColor` 正在 `colorInvert` 的属性清单里。（`font_primary` 数值与之相同；选 `icon_primary` 是因为画的是图标。两个名字都在 SDK 的 `toolchains/id_defined.json` 里，`$r` 编译得过。）
- **`colorInvert` 必须显式为 `true`**：它 `@since 26.0.0`、**默认 false**（`@ohos.arkui.uiMaterial.d.ts:380`），不设等于这套资源只是**静态**解析。所以本轮的材质是**新的一个 builder**：`immersiveHeaderBarMaterialOption()`（`THIN` + `colorInvert: true`），**阅读器那个 `immersiveTopBarMaterialOption()` 一个字节都没改**（审计有一条**平面否定**钉住它不含 `colorInvert`）。可用性判定走 Theme.ets 里**新的** `headerBarMaterialOption()`，它把 `topBarMaterialOption()` 的两条拒绝（`materialOption()` 的 API/设备门、`materialLevelPaintsBackground()` 的低算力档）**按同样顺序再问一遍**——审计切片两个函数体、要求两条拒绝的出现序列完全一致，所以两份不会漂。
- **透明度不需要分支**：`sys.color.icon_primary` 在两种表面、三个主题上的合成对比度实测 **17.404 / 15.541（亮）、13.606 / 15.149（暗）、14.994 / 14.463（护眼）:1**（`#E5` 自身 alpha 合成；两种表面分别是无材质分支的 `palette.card` 与材质所覆的页面底色）。**六个数字全部远高于 4.5:1**，所以**没有**为无材质设备加第二个颜色分支——这正是「先测再决定」省下来的一整棵树。
- **48 vp 点击盒与 `accessibilityText` 未动**（`MIN_TAP_TARGET`；`this.syncBusy ? '同步进行中' : '同步'` / `'导入'`）；`stateEffect: true` 也未动。
- **`LoadingProgress` 的环不在表1 上**：`colorInvert` 的属性清单里**没有 `LoadingProgress.color`**，所以忙碌环是**静态**着色（用的是同一个资源，因此和字形同色）——已记在代码注释里，别当成「它也会反色」。

**⑥ 没有动的东西**：`ReaderView.ets` 一个字都没改（所以 strip 探针 9 个锚点行号**完全不变**）；shell 的根 `Navigation`/`settingsPathStack`/`settingsPagesMap`/r107 两个 inset/`HdsTabs`/浮动页签栏/`barBottomMargin`；Grid 的 `contentEndOffset` 与**无底部 padding**（连调用点都没碰）；r117 的封面进度条、百分比行、673.5 px 行高、`MENU_TRIGGER_INSET`；r116 的阅读器挂载写状态栏与同步页单一内缩；同步逻辑、`Rdb.ets` 的 `queueBusy`、墓碑上界、线格式。**没有新增任何十六进制颜色字面量**（`Color.Transparent` 是枚举，`sys.color.*` 是资源）。

**⑦ 搜索框（用户没让改，所以没改）**：SDK 的 `Search` 参考文档为 placeholder（`#99182431`）、输入文字（`#FF182431`）、searchIcon、cancelButton 都给了**默认值**，但**没有声明默认 `backgroundColor`**；应用也没有给它设背景。所以「它到底有没有在不透明胶囊上盖住材质」**在声明层面无法判定**（需要真机像素采样），本轮**不动它**并如实上报；如果真机上它确实盖住了，那与两个按钮是**同一个缺陷**（控件自己的背景在材质层之上）。

**审计**：30 工具 / **3739** 项 / 3739 通过 / 0 失败（基线 **3726** → 净 **+13**：`verify-book-menu` 257 → **266**、`verify-themes` 226 → **230**；`verify-reader-chrome` **412 → 412 但那条 band 断言改强**、`verify-motion` 148 → 148）。裸 `Select-String 'passed'` 仍是 **34** 行（30 个工具）。失败集合 **∅**。
- **改写的断言（每条都等价或更强）**：`the title's space is reserved rather than reclaimed` → **`the title's region is reclaimed…`**（反转到不变量本身，并**新增**「一个机制」的性质：`height` 之外的五种布局手法 + `clip` 全部否定）；「builder 里恰好 2 次 `titleHidden`」→ **「全文恰好 4 次，且 builder 3 次 + `headerBarCurrentHeight` 1 次」**（旧口径看不见 builder 之外的读者，新的那个恰好在外面）；两个按钮的「`primary` 填充 + `primaryForeground` 字形」→ **「无填充（显式 `Color.Transparent`）+ 表1 的 `icon_primary`，且整个 builder 里不出现 `this.palette.`」**（更强：旧的只查一个角色，新的否定了整类）；`verify-themes` 的「glyph on fill ≥ 4.5:1」一条 → **两条**（`palette.card` 与页面底色各一条，且资源按**应用自己的系统模式映射**解析）；`verify-reader-chrome` 的 band 断言从「一个高度」→ **「两个高度都花掉这条 band」**。
- **新增的断言**（`verify-book-menu` +9）：两个高度的**项表**（按项列表断言，不是魔数）、`headerBarCurrentHeight` 是三选一的唯一入口、**材质载体在两个分支都等于当前高度且不再是 `'100%'`**、两个高度**求值**（138.25 / 103 / 差 35.25）、**恰好 4 个 `headerBarCurrentHeight()` 调用点且位置点名**、`headerBarCollapsedHeight` 也花掉 band、**材质 builder 是 `THIN` + `colorInvert: true`**、**阅读器的 builder 不含 `colorInvert`（平面否定）**、两个决策函数**拒绝序列一致且各自 `catch` 后落回自己的 builder**、页面**只问一次、只花一次**、以及 `verify-themes` 新增的「系统色彩模式仍由应用主题推导（`dark: this.themeMode === 'dark'`）」——**这一条是护眼那一组数字成立的前提**（把护眼映射成系统深色 → 近白字形压在 `#F5EBD7` 上约 1.03:1，会消失）。
- `.diag/r119-mutate.mjs`：**27/27 全被抓、4 条 control 全绿、0 条 NOT APPLIED、5 个源文件 sha256 逐字节还原**。**第一轮跑出 1 条 NOT CAUGHT，而且它抓的是我自己的假断言**：`verify-themes` 那条用 `shelf.includes(...)` 查「资源出现过没有」，所以只把**导入**按钮换成 `sys.color.font_secondary` 时，**同步**按钮那次出现仍把它撑绿 → 改成**把整页的 `fontColor([$r('sys.color.*')])` 列成表**并与 `['sys.color.icon_primary','sys.color.icon_primary']` 全等，复跑通过。另外两条 first-run 失败都在**变异脚本自己**（两个 `body()` 锚点漏了 `: number` 返回类型标注；`want` 少了正则捕获进去的右括号）——**检查是对的，锚点是错的**。

**产物**：`entry/build/default/outputs/default/entry-default-unsigned.hap`，**1,920,599 字节**，sha256 **`9467fe07ba9fcb6378d4f3d38890e05c095e7802e661e3029496dc94999d5da4`**，未签名（`Will skip sign 'hos_hap'`），由用户手动安装。**增量与 `clean` 后构建都 `BUILD SUCCESSFUL`。** 本地提交 **`3df9c1d`**（未推送）。

`.diag/strip-sheet-probe.mjs`：**9 个块 / 31 个标记**、`PROBE FULLY REMOVED: true`、`chars 262340 -> 253463; lines 4726 -> 4584`，锚点 **506 / 833 / 930 / 3737 / 3771 / 3802 / 3908 / 4601 / 4625** —— **与 r116/r118 记录完全一致，因为本轮同样一个字都没改 `ReaderView.ets`**。

**未验（不许当成已验）**：**设备本轮全程 `Offline`**（`hdc list targets -v` = `<device-ip>:<hdc-port> TCP Offline`），**一个真机数字都没有，也没有注入任何手势**。必须装机核对，**两个方向、三个主题**：
- **上划 → 隐藏**：标题淡出上移的同时**整块区域收起**，搜索框/同步/导入**上移到标题原来的框位置**；头部总高从 138.25 降到 103 vp，网格顶边上移 35.25 vp；材质**恰好**覆盖这 103 vp，**没有**在材质下面留一条没上色的带，也**没有**把材质画到 bar 盒子外面；
- **下滑或回到顶部 → 恢复**：标题区域**重新长出来**，网格顶边下移回去，标题淡入下移；带内（12 vp 以内）来回滑**什么都不动**；
- **「设置 → 动画」关闭**：收起与淡出**同一帧内瞬间完成**（不是 0 时长）；
- **三主题**下：两个圆形按钮**没有填充**，材质**透过它们可见**，字形在材质上**清楚可读**（`icon_primary` 的静态值与自动反色各看一眼）；搜索框保持在材质之上、宽度仍约 247.1 vp；
- **无材质设备/低算力档**（若可得）：头部是 `palette.card` 实心面，两个按钮仍是透明、字形仍是 `icon_primary`（对比度 17.4/13.6/15.0:1），**几何与有材质时完全一样**；
- 进「设置 → 同步」再返回，浮动页签栏与头部都还在；书架与另外两个 tab 之间来回切时标题栏内容正确。

### r118：书架头部（搜索框 + 同步/导入两个图标按钮）改「真沉浸光感」，书架标题上划隐藏（**已完成构建与审计，未装机验收；其中两条做法已被 r119 推翻，见上一节**）

用户三条原话：「**我想修改主界面的同步和导入按钮，让这两个按钮也支持沉浸光感。让搜索框也支持沉浸光感。我还想上划的时候就隐藏"书架"标题。**」

**① 作用域：这次不是「不可能」，而是「换个位置就可能」。** 项目原有的规则（§4.2 / §6 第 14 条）这次被**从声明和 MCP 两处复核并确认**，而且查到了原来没记录的那一句——**官方自己的补救办法就是把组件搬进标题栏**：

- **开启沉浸光感**（`harmonyos-guides/arkts-immersive-light-sense-enable`）：「**其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感效果不生效。**」例外只有：弹窗类组件/接口、`Slider`/`Toggle`/`Select`。
- **沉浸光感常见问题 · 组件不在沉浸光感生效范围**（`…-faq`）给出运行时症状「日志中存在打印：`Material inactive: out of scope. Use component in navigation title bar or Tabbar.`」，以及 **解决措施**：「**将需要沉浸光感效果的组件置于 Navigation/NavDestination 标题栏…中**。若无法满足生效范围要求，可改用 backgroundColor 等通用属性替代材质效果。」——它的示例正是「标题栏里的 `Column` 带材质生效 / 内容区里同一个 `Column` 不生效」。
- **沉浸光感功耗优化**（`…-constraints`）的**正例**：「在Navigation标题栏中**为局部容器**设置沉浸式系统材质，材质生效且面积可控」；反例是整页容器。
- **沉浸光感典型场景 · 搜索框标题栏效果**（`…-sample`）**就是本轮要做的事**：标题栏里放大标题 + `Search(...).systemMaterial(...)` 两个动作按钮，`Scroll.onDidScroll` 里按偏移隐藏/缩小搜索框，`barStyle: BarStyle.STACK`；文档原话「用户上滑首页内容区后，标题栏显示范围可随之缩小」「上滑时搜索框隐藏，分类列表保留并突出显示」。
- **按钮（Button）那一节**还把这句话又写了一遍：「本组件沉浸光感效果仅在Navigation/NavDestination标题栏或横向Tabs中barPosition为BarPosition.End的底部TabBar中生效。在其他区域中设置沉浸光感效果不生效。」并且：材质样式为 THIN/ULTRA_THIN 时 `fontColor` 用系统可反色资源会自动反色（**用调色板硬编码颜色不会反色**——所以本轮的按钮不各自加材质，见下）。

**② 做法：`ShelfPage` 自己长出一个只当材质宿主的 `Navigation`，不重构 shell。** 这是本轮最重要的一条「省下来的代价」：

- `ShelfPage` 的 `build()` 第一个子节点是 `headerBar()`：`Navigation()` **没有内容、没有 `NavPathStack`、没有 destination**，`.hideBackButton(true)`，`.title({ builder: this.materialHeaderTitle, height: this.headerBarHeight() }, { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })`，`.expandSafeArea([], [])`。它**按布局占位**（不像阅读器那样 `position` 浮起），所以网格自然从它下面开始，不需要 `contentStartOffset`，也没有第二个量去对齐。
- **形状照抄 `ReaderView.topBar`**（本项目已有的、已验证的材质宿主），所以全应用只有一种「怎么承载材质」的写法。区别只有两个：阅读器那个是 `position` 浮层（因为 kit 的分页盒不能动），这个是布局里的普通兄弟节点（因为网格不测量标题栏）。
- **材质挂在标题栏里的一个局部容器上**（`materialHeaderTitle` 里那个填满 bar 的 `Column`），不是挂在 bar 自己身上——正例的原话。它走的是应用**已有的**那个受保护决策点 `topBarMaterialOption()`（→ `immersiveMaterialAvailable()` → `canApplyImmersiveMaterial()`），和阅读器顶栏同一个入口；`undefined` 覆盖三条「无材质」路径（API 缺失 / 设备不支持 / 低算力档），此时 `materialHeaderTitle` 走另一分支画 `palette.card`。
- **`systemMaterial` 不往三个控件上分别加。** 一个 `Search` 或 `Button` 自己的 `backgroundColor` 会盖住材质层（常见问题：材质视觉层级在 `backgroundColor`/`backgroundBlurStyle` **之下**），而那两个圆形按钮现在的填充是 `palette.primary`；分别加材质就等于把它们的填充换掉，那是本项目已经吃过两次亏的「系统材质只懂明暗 → 护眼主题被刷白」。所以是**一个容器一体化材质**，控件保持调色板填充，它不可反色——这是**有意接受的代价**，不是遗漏。
- **没有动的**：shell 自己的根 `Navigation`、`settingsPathStack`、`settingsPagesMap`、r107 两个 inset、`HdsTabs` 外壳、浮动页签栏、`barBottomMargin`、Grid 的 `contentEndOffset` 与「无底部 padding」、`!/barWidth\s*:/`。**Route A 的真实代价只有两条**：（a）书架标题栏占掉的高度是 `topInsetVp + SPACE_S + 30×1.175 + SPACE_S + 48 ≈ 139 vp`（原先标题行约 75 vp），所以网格的可见高度少了约 64 vp；（b）**书架标题搬进了这个 bar**，因为标题栏的内容只能是 `ShelfPage` 的 builder，`Index` 再画一份就是两个「书架」。

**③ 「书架」标题：搬进头部，`@Prop pageTitle: string` 由 shell 传入。** 审计里那条「三个页面各有一个大标题」从 3 条改成 **2 条 + 1 条配对断言**：`pageTitle` 仍存在且仍给另外两个 tab 用（所以 shell **没有**多出第二个决定「band 到哪儿结束」的地方），而书架的标题由 `ShelfPage.headerTitle()` 画，**和 `pageTitle` 用同一组 token**（`TYPE_TITLE_LARGE` / `Bold` / `palette.foreground` / `maxLines(1)` / `Ellipsis`），**两边同时断言**，所以以后改一边不动另一边会失败。

**④ 上划隐藏：`onDidScroll` + 双阈值带 + 只动 `opacity`/`translate`。**

- **API 是查出来的**：`onDidScroll(handler: OnScrollCallback)`，`common.d.ts:25435`，**`@since 12`**（低于本模块 `compatibleSdkVersion` 24，**不需要运行时守卫**）。回调 `(scrollOffset, scrollState)`；声明原话「**scrollOffset is offset per frame scrolling**」——**是每帧增量，不是位置**，所以累加。**`onScroll` 是错的**：`@since 11` 但 **`@deprecated since 12`**，`@useinstead` 正是 `onDidScroll`（`common.d.ts:25407-25408`），而且它不吃 `ScrollState`。**`ScrollState` 本轮不分叉**：用户说的是「上划」= 方向，不是手势阶段，而 `ScrollState`（Idle/Scroll/Fling）本身也不含方向。
- **规则是带，不是比较器**：`onDidScroll` 每帧给一个增量，按每帧符号翻转会在手指抖动时闪烁。所以 `ShelfPage` 只上报 `(up = delta > 0, offset = 累加值)`，**判定在 shell**：`shouldHide = !(offset <= HEADER_TITLE_SHOW_AT) && (up || this.shelfTitleHidden)`。常量在 `Tokens.ets`：`HEADER_TITLE_HIDE_THRESHOLD = 24`、`HEADER_TITLE_SHOW_AT = 12`（**带 = 12 vp 的迟滞**）。
  - **为什么「显示」那一侧不要求向下滑**：r108 量过这个网格的总滚动范围只有约 857 px，用户滑一点点就到头停下；只认反向的话标题会**卡在隐藏态且再没有手势能让它回来**。回到顶部也在 12 vp 带内（`EdgeEffect` 的弹簧会把 `scrollOffset` 带回 0）。
- **标题的空间是「预留」不是「收回」**：`headerTitle` 的高度是常量 `headerTitleHeight()`（`TYPE_TITLE_LARGE × 1.175`，1.175 em 是参考机实测的行盒比），**不是** `titleHidden ? 0 : …`；只驱动 `.opacity(...)` 和 `.translate({y: -12})`（`HEADER_TITLE_HIDE_OFFSET`），**恰好两处读 `titleHidden`——审计数这个数**。理由：标题那一行同时是标题栏的内容，而标题栏的高度就是网格向下让出的距离，**收起它 = 在滚动过程中让网格长高 ~44 vp**——正是本项目已经付过两次代价的那类问题（r109 的整行 pop 就在这个 Grid 上，阅读器的重新分页）。可见代价是滚下去时状态栏下面约 44 vp 空白；收益是屏幕上除了标题本身什么都不动。
- **动效门控**：`Index.applyShelfTitleHidden` 用 `this.animationOn`（`@StorageLink(MOTION_ON_KEY)`）判断，**关闭时直接赋值、不进 `animateTo`**——不是 `duration: 0`（那仍会开一个动画上下文并跑一帧插值）；弹簧 `curves.springMotion(HEADER_TITLE_RESPONSE, HEADER_TITLE_DAMPING)`（`0.45/0.85`，**放 `Tokens.ets` 里一份，因为有两个读者**），**不传 `duration`**（弹簧曲线下 `duration` 不生效，SDK 明说）。
- **`Index` 现在有一个 `animateTo`**，而 r113 把「`Index` 一个动画都没有」写成了断言。那条**反转成「恰好一个、且钉在 `applyShelfTitleHidden` 里」**（比「没有」更强：能说出是哪一个），`onAppear` 仍是硬否定。`this.animationOn` 读者数 **4 → 5**，同样按名列出。

**⑤ 顺带被这条规则救回来的两个坑**（都是真跑出来的，不是想到的）：
- 注释里写 `EdgeEffect.Spring` 会让 `verify-motion` 的「页面里不许出现无条件的 EdgeEffect 字面量」失败——**它扫注释**。两处注释已改写。
- `verify-book-menu` 那条 `contentEndOffset` 检查原本对**整个 ShelfPage 文件**否定 `canIUse|sdkApiVersion|apiLevel|canApplyImmersiveMaterial`；本轮 `ShelfPage` 合法地有了一个 API-26 门（材质），所以**否定收窄到 `contentEndOffset` 调用点那 200 字符**——它守的本来是「预留是无条件的」。

**审计**：30 工具 / **3726** 项 / 3726 通过 / 0 失败（基线 **3706** → 净 **+20**：`verify-book-menu` 239 → **257**、`verify-reader-chrome` 410 → **412**、`verify-motion` 148 → 148（改 2 条）。其余 27 个工具逐条相同；`verify-book-menu` 的 BUILD_STAMP 钉子从 r117 改到 r118）。裸 `Select-String 'passed'` 仍是 **34** 行。失败集合 **∅**。
- **改写的断言**：`Index` 的「一个动画都没有」→「恰好一个，且在 `applyShelfHidden` 里」（更强）；`animationOn` 读者 4 → 5（更强：多了的必须叫得出名字）；书架 `pageTitle` 3 → 2 + 三条新配对断言（更强：两个渲染器必须同 token）；`topInsetVp` 的 shell 读者 4 → 5（更强：新增的那个必须同时有「传」和「接」两条）；`no section re-applies the top inset to its content` → 收窄成「**不许 padding**，但允许把 band 交给标题栏」，并新增两条把这次交接的两端都钉住。
- **新增的断言**（`verify-book-menu` 新开一节 18 条）：材质只在标题栏 builder 里、**两个分支各画一次** headerRow/headerTitle、整个 `build` 挂上 `headerBar`、`systemMaterial` 在这个文件里**恰好 1 处且在 `materialHeaderTitle` 内**、`onDidScroll` **恰好 1 处**且没用已废弃的 `onScroll`、回调**不读 `ScrollState`**、累加而不是赋值、累加器在 `aboutToAppear` 里清零、两个阈值都被定位且 `SHOW_AT < HIDE_THRESHOLD`、规则的两侧都按 offset 读、动效门控且**没有 `duration: 0`**（从**去注释**源码上取）、弹簧是命名 token 而不是内联字面量、标题高度不随 `titleHidden` 变且没有 `padding/margin/layoutWeight/position/offset`、**`titleHidden` 恰好读 2 次**、`translate` 距离是 token 且小于一个行盒、shell 持有状态而页面**不写**它、网格把方向**和**距离两个数都上交。
- `.diag/r118-mutate.mjs`：**26/26 全被抓、0 条 NOT APPLIED、3 条 control 全绿、三个源文件 sha256 逐字节还原**。**第一轮跑出 6 条 NOT CAUGHT，其中 5 条是我自己的断言太弱，全部改强后复跑通过**（清单值得记：`materialHeaderTitle` 那条用了跨文件的 lazy 正则，所以「第一分支删掉 `headerRow()`」穿过去了 → 改成按花括号切片 + **两个分支各数一次**；`headerTitle` 的「不在滚动容器里」用了 `rowEnd` 锚点，切片吞掉了整个 `build()`；累加器归零那条的 `[\s\S]*?` 没有闭合边界；`duration: 0` 那条没过 `codeOnly`，被自己的注释满足；「把方向和距离都上交」那条只钉了回调形状和网格侧的调用，没钉 shell 的 `(up, offset)` 透传）。第 6 条是**变异脚本自己的锚点写错**（`pageTitle: '书架',` 在 `Index.ets` 不在 `ShelfPage.ets`）。另外**变异脚本第一版用 `latin1` 解码**，把 `书架` 拆成 3 个字节，导致 7 条 `NOT APPLIED`——已改成 `utf8` 解码、只用 `latin1` 嗅探行尾。

**产物**：`entry/build/default/outputs/default/entry-default-unsigned.hap`，**1,917,948 字节**，sha256 **`b9471e23b903a55be6f01166c3ba86cbe8b2f23d3b99e04d88288893e599f144`**，未签名（`Will skip sign 'hos_hap'`），由用户手动安装。**增量与 `clean` 后构建都 `BUILD SUCCESSFUL`。** 本地提交 **`94b2087`**（未推送）。

`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块 / 31 个标记**、`PROBE FULLY REMOVED: true`、`chars 262340 -> 253463; lines 4726 -> 4584`——**锚点行号与 r116 记录的完全一致，因为本轮一个字都没改 `ReaderView.ets`**。

**未验（不许当成已验）**：**设备本轮全程 `Offline`**（`hdc list targets -v` = `<device-ip>:<hdc-port> TCP Offline`），所以**一个真机数字都没有，也没有注入任何手势**；hvigor 也连不上设备，安装与否无从判断。必须装机核对：**三主题下**——(a) 搜索框与两个圆形按钮**坐在材质表面上**（不是各自一块材质），底下的书封面滚动时能从薄材质里透出来；(b) 低算力/不支持设备上是 `palette.card` 的实心头部、**几何完全一样**；(c) 头部右边缘落在屏内（约 1266 而不是 1320），搜索框宽约 247.1 vp；(d) 标题首行墨迹仍在状态栏之下，**没有**被压到挖孔里；(e) **上滑隐藏、下滑或回到顶部恢复**，隐藏时**搜索框和两个按钮不动**、网格不跳；(f) 「设置 → 动画」选「关闭」时标题**瞬间**切换（不是 0 时长）；(g) 书架与另外两个 tab 之间来回切时标题栏内容正确；(h) 进「设置 → 同步」再返回，浮动页签栏与头部都还在。

### r116：阅读器挂载时写状态栏 + 同步设置页的横向内缩（**已完成构建与审计；真机证据来自 r115 那份 dump 与截图，修复本身未装机验收**）

三个任务：补文档（本节 + §3.2/§5 + §8 的两处修正）、阅读器入场状态栏、同步页布局。

**① 阅读器挂载时写一次状态栏（r107 自己点名的那个补救）**

用户原话：「阅读界面的信号栏，在主界面点进阅读界面的时候是显示的，要呼出一次阅读界面的顶栏和底栏才会隐藏。」**这正是 r107 记录在案的漂移**：阅读器只在「切两栏」和「卸载」时写状态栏，所以刚打开的书**继承 shell 的可见基线**（r107 之后是 `true`），第一次中间点击之后才与 `barsVisible` 同步。**r107 找到了这一行、没有写**（那一轮被授权只改卸载那一个值）。

- **改动**：`ReaderView.aboutToAppear` 里加一行 `this.applyReaderStatusBar(false)`，调用点 **2 → 3**。
- **四态机（写进 `applyReaderStatusBar` 的文档 + 断言）**：**shell 基线 `true`**（`Index.applySystemAppearance`）→ **阅读器挂载 `false`**（`aboutToAppear`）→ **每次切栏 `barsVisible`**（`toggleBars`，唯一带 `enableAnimation` 的一处）→ **卸载 `true`**（`aboutToDisappear`，唯一卸载路径，值必须等于 shell 基线）。
- **次序是查出来的，不是假设的**：另一个 app 级写者 `Index.applySystemAppearance` 由 **`Index.aboutToAppear`** 发出（父组件的 `aboutToAppear` 先于子组件），且那次写入是一条 `getLastWindow().then()` 的**异步窗口请求**，在启动时就发出；而阅读器组件是**用户点书**时才创建的，所以挂载这一行**严格晚于** shell 那次请求落地 → **它是挂载时的最后一句话**。（阅读器替换 shell，主题选择器在 shell 的「设置」页，所以宿主写者不可能在阅读器挂载期间再跑。）
- **一处额外交代**：`applyReaderStatusBar` 的**日志标签**跟着改了——三个调用点只有两种参数形态，所以「两参数分支」现在按**值**分辨调用者（`visible ? 'app-wide baseline' : 'reader mount, bars down'`）。不改的话，挂载这次写入会被日志报成「app-wide baseline」，正好是下一轮排查时最容易被误导的一句。**只改标签，没动调用形态、没动动画、没动 `toggleBars`。**
- **断言是「等价或更强」的改写，不是放宽**：原来那条 `the reader has exactly two callers of that helper`（计数 2）改写成 **计数恰好 3**，并且**每个调用点钉到它自己的方法上**（挂载在 `aboutToAppear`、值必须是 `false`、`exactly one of the three callers animates`、挂载值与卸载值必须**不等**——「不等」正是日志标签成立的前提）。**跨文件那条「卸载值 == shell 基线」保持不变，而且更强了**：两个值现在都**从各自方法体内**提取，不再靠「全文件第一个 4 空格缩进的这种调用」——挂载那行是第二个这种调用，旧写法会开始拿**挂载值**去和 shell 比。

**② 同步设置页的横向内缩：测量出来的，不是目视的**

用户原话：「布局还有点小问题…边框都超出了手机」。**根因是 ArkUI 的盒模型：`width('100%')` 的子节点按父节点 content box 解析、且不会因为自己的 `margin` 而缩小**，所以 `.width('100%')` + `.margin({ left: 16, right: 16 })` 实际是 **100% + 32vp 宽**：左 margin 把元素右移，右 margin 落到屏幕外。

设备实测（**r115 那份仍在设备上的构建**，`.diag/r116/layout.json` 用 `uitest dumpLayout`——和 r108 量书架是同一件仪器；以及 `.diag/r116/now.jpeg` 的逐行像素扫描）：

| 元素 | 实测 x 范围（屏宽 1320） | 结论 |
|---|---|---|
| 进度卡（`syncProgressDeterminate` 的白底） | **58 → 1319** | **溢出**：右边缘就是屏幕最后一行像素，`0%`/`85%` 标签被切 |
| `planProbeSection` 面板 | **[54, 1320]**（dump 在屏幕边被裁） | **同一个缺陷**，也在溢出 |
| 它的兄弟 `同步参数` 面板 | **[54, 1266]** | 正常：两侧各留 54px = 16vp |
| 四个凭据输入框（用户名 / 密码 / 远程目录） | **约 [56..64, 1255..1263]** | **正常，两侧都有 48–64px（≈14–19vp）的页底色** |

**所以是「两个问题看似一个」**：进度卡**确实**在溢出；**四个凭据框没有**（用户把它们和进度卡一起看成了「没有边距」，但像素扫描显示它们两侧各有约 16vp 的底色）。而用户以为「下面几张卡是内缩的」——`同步参数` 是，`文件同步决策自检 / 网络方法自检` 那张**不是**（它就是 dump 里 [54,1320] 的那个）。**这是缺陷，不是本页的约定**：同一页上两张同类卡片的内缩不同，而且其中一张的信息被屏幕切掉。

**修法：把内缩提到唯一的父节点上，页面只剩一处内缩**，每个子节点都是那个盒子的普通 `width('100%')`。`syncSection` 的内容列从 `padding({ bottom: FLOATING_BAR_CLEARANCE })` 改成 `padding({ left: SPACE_M, right: SPACE_M, bottom: FLOATING_BAR_CLEARANCE })`；四行各自的左右 padding 与两张卡的左右 margin、以及 `SyncSettingsPage` 自己的左右 padding 一起拿掉。**渲染几何只有那两张溢出的卡变了**——16vp 在 100% 宽的盒子里和 16vp 的 padding 是同一个 16vp。

**底部内缩：不需要，而且有两条证据。** ① 代码：`settingsPagesMap('sync')` 是 `NavDestination`，外层是 `.mode(NavigationMode.Stack)` 的 `Navigation`——**在 Stack 模式下被 push 的 `NavDestination` 铺满整个内容区**，所以浮动的页签栏被它盖住（这正是 r107 留下 `syncSection` 的原话）；② 设备：那份 dump 里**有 `NavDestination`/`NavDestinationContent`，一个 `Tabs` 节点都没有**，也没有任何底栏节点。它自己的 `FLOATING_BAR_CLEARANCE`(96) 只是余量，本来也不是为浮栏付的。

**③ 文档（Task 1，唯一写者）**：补了 §9 的 r113/r114/r115 三条；§3.2/§5 的基线从 `3459` 更新为 **`3633`**（并补上 r102→r116 的完整沿革，包括 **r113 那一次负增长**）；§8 修正了两个**被当成不变量、而且已经误导过一轮**的错误说法（见 §8 同步的第一条），并新增「`sync_version` 不是同步判据」。

**审计**：30 工具 / **3633** 项 / 3633 通过 / 0 失败（基线 3623 → 净 **+10**：`verify-reader-chrome` 402 → **410**、`verify-sync-progress` 151 → **153**；其余 28 个工具逐条相同；`verify-book-menu` 的 BUILD_STAMP 钉子从 r115 改到 r116，**184 条不变**）。失败集合 **∅**。裸 `Select-String 'passed'` 仍是 **34** 行（30 个工具）。

- **改写的断言**：`exactly two callers` → `exactly three callers`（+ 每个调用点各一条，**更强**）；`and the log names which caller wrote the bar` → 三个调用者一起命名（**更强**）；`the unmount restores the same value the shell writes` 与 `the unmount path writes the baseline back unconditionally` 两条的**取值来源改成各自方法体**（**更强**：旧写法在挂载写入出现后会把挂载值当成卸载值）。
- **新增的断言**：挂载方法被定位、挂载值必须是 `false`、**恰好一个调用点带动画**、挂载值与卸载值必须不等；同步页内容列拥有唯一内缩、**每个绘制该页的 builder 都被定位**（锚点漂移就大声失败，不许在空切片上通过）、整页**恰好一处**横向内缩、`SyncSettingsPage` 自己不内缩；两张进度卡各一条「不许自己加横向 margin」。
- **变异测试** `.diag/r116-mutate.mjs`：**16/16，0 条 NOT APPLIED、0 条 NOT CAUGHT、0 条 WRONG CHECK**；两个 control（只改注释、只把违规写法写进注释）保持全绿；三个源文件**逐字节还原**（sha256）。**第一轮抓出了我自己两条假断言**：最初那两条 Task 3 断言只扫 `syncSection` 的方法体，而**真正溢出的两个元素画在别的 builder 里**（`syncProgressDeterminate` / `planProbeSection`），所以变异 10、11 直接穿过去（`NOT CAUGHT`）。改成「列出全部 builder + 整页恰好一处内缩」后才抓到。**行尾按文件探测**：`Index.ets` 是 CRLF，`ReaderView.ets`/`SyncSettingsPage.ets` 是 LF（简报里猜 `SyncSettingsPage` 是 CRLF，**实测是 LF**）。

**产物**：`entry/build/default/outputs/default/entry-default-unsigned.hap`，**1,890,141 字节**，sha256 **`f95f41475c5f50f8e9eb2c55cc81b0708ea35de1a5965fecc483982804fb9878`**，未签名（`Will skip sign 'hos_hap'`），由用户手动安装。**增量构建与 `clean` 后构建都 `BUILD SUCCESSFUL`。**

`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块 / 31 个标记**，`PROBE FULLY REMOVED: true`；本轮**改过 `ReaderView.ets`（+53 行）**，所以六个锚点行号整体后移 53 行：**506 / 833 / 930 / 3737 / 3771 / 3802 / 3908 / 4601 / 4625**（前三个在插入点之前，未动）。

**未验（不许当成已验）**：**修复本身没有装机验收**（HAP 无签名，按既定流程只能由用户安装）。设备当时是 `Connected`，但前台是**桌面**（`com.ohos.sceneboard`）、InkBoat 未运行、**cloudmusic 在放音乐**，按「用户在用就不要注入手势」的规则**没有注入任何手势**：所有真机数字都来自**设备上已装的上一版（r115）留下的 dump 与截图**，不是本轮构建的。必须装机核对：从 shell 点进阅读器时**信号栏直接不显示**、抬栏/收栏时它跟着走、退出阅读器后 shell 的信号栏还在；同步页的进度卡与自检卡**右边缘落在屏内**（应当与 `同步参数` 卡一样是 1266 而不是 1320）、`0%` 标签完整；三主题下都是如此。

### r115：无封面占位书名再缩一半（24 → 12 fp），并记录由此失去的护眼对比豁免（**已完成构建与审计，未装机验收**）

**用户原话**：「封面上的书名可以再小一点，先取现在的50%我看看。」所以 `PLACEHOLDER_TITLE_SIZE` **24 → 12 fp**，仍是命名 token、没有内联字面量；`ShelfPage.ets` 的绘制点一字未改。

**durable consequence（这是本轮真正要记住的东西）**：占位那一对颜色（`placeholderForeground` on `placeholderSurface`）实测 **亮色 4.636:1 / 暗色 5.489:1 / 护眼 3.916:1**。**对比度与字号无关，三个数字一个都没变**；变的是**适用哪条下限**：亮色/暗色仍 ≥ 4.5:1（项目的正文下限），而**护眼 3.916:1 < 4.5:1**。r114 之所以合法，靠的是 **WCAG 大字号豁免（3:1）**，而豁免的前提正是字号——**24 fp 恰好是 18pt = 24px 那道门槛，12 fp 不再满足它**。所以护眼这组现在是**真实的、低于正文下限的短板**（只是仍高于绝对的 3:1）。**这是已记录、刻意的偏离**：调色板值属于用户的决定，所以本轮**一个调色板值都没动**，理由写在 `Tokens.ets` 那个 token 的注释里，紧挨着这个尺寸。

**容量（用 r114 实测的 line-box 比例，不是假设的 1.4）**：12 fp 的行盒实测 **1.161 em**、28 fp 的 **1.175 em**（保守上界）。内盒 350×512 px、一个汉字 40.5 px → 每行 8 字、盒子自己装得下 10 行，**实际被 `maxLines(5)` 夹住** → **容量 40 个汉字（8 × 5）= r114 的两倍**。**约束从「盒子」换成了 `maxLines(5)`**：24 fp 时 floor(512/95.2)=5，夹子和几何说的是同一句话；12 fp 时盒子装得下 10 行，**是夹子把它停在 5 行**。13 字的 `斗罗大陆2绝世唐门足交传说` 现在只占 2 行。

**封面盒与 636 px 行高不变**：封面 `Stack` 是 `width('100%')` + `aspectRatio(0.7)`（377/0.7 = 539 px），本轮变小的是 `Text` 的**实测高**（476 → 235 px），只会让子节点更小。

**审计**：30 工具 / **3623** 项 / 3623 通过 / 0 失败（基线 3621 → 净 **+2**，全部在 `verify-themes` 206 → **208**）。`verify-themes` 那条 `PLACEHOLDER_TITLE_SIZE >= 24` 的前提被用户**按需求推翻**，所以**改指到不变量本身**（3 条 → 5 条，**更强**）：原来那条变成 `< 24`，另外**新增两条**——① 护眼那组必须**从调色板现算并实测**低于 4.5:1（记录与调色板因此无法互相漂移；将来谁把护眼抬回下限之上，这条会失败并提示「记录已过期」），② `Tokens.ets` 必须同时含 `reduced at the user's request` / `below the large-text exemption` / `recorded, deliberate departure` / `3.916:1` / `4.5:1` 这**五个短语**。**第 ② 点是旧阈值从来没有过的**：24 fp 时整个「为什么」可以被删得干干净净而检查照样通过。`.diag/r115-mutate.mjs`：**19/19 全被抓、0 条 NOT APPLIED**，两条 control 保持绿；其中两条第一次跑是 `NOT CAUGHT`，根因是**变异脚本自己的锚点写错了**（改的是注释标题行，被检查的短语在正文里；`4.5:1` 在文件里有 4 处，只删 1 处等于没删）——**检查是对的，锚点是错的**，两处已重写并复跑通过。

**未验（不许当成已验）**：设备在本轮中途变为 `Offline`，且 HAP 无签名只能由用户安装，所以 **r115 的真机数字一个都没有**。636 px 行高与「文字仍在灰盒内」目前只有算术与 r108 的历史实测支撑。

### r114：书架格子的三处修正（操作按钮收进封面 / 书名单行省略 / 无封面显示完整书名）（**已完成构建与审计，未装机验收**）

**用户看着装好的构建提的三条**：「书籍的操作按钮会超出书籍封面的范围，和文字重叠」/「当文字有两行的时候，会换行导致布局被破坏，解决方法是书名只有一行，超出字数限制用省略号」/「没有封面的书，在封面的位置显示完整的书名，字号比现在小一点」。三条都在 `ShelfPage.ets` 的 `bookCell` 里。

**依据不是估算，而是 r108 留在仓库里的真机布局 dump**（`.diag/ink_layout.json`，9 个 `GridItem`、逐块 bounds）。px 与 vp 的换算是密度 3.375。

**① 操作按钮：锚点是对的，符号是错的。** dump 里旧几何：封面盒 377×539 px、封面下沿 y=1072；可见圆片 32vp=`MENU_TRIGGER_SIZE` 落在 y 1018→**1126**，点击盒 48vp 落在 y 964→**1126**——**两者都比封面下沿低 54 px = 16.0 vp**，而书名首行从封面下沿 +6 vp 开始（y 1092），于是**圆片与书名首行重叠 34 px = 10.1 vp**。那 16 vp 就是 `.offset({ x: 0, y: MENU_TRIGGER_SIZE / 2 })`：**外盒已经对齐在封面右下角，再向下推半颗圆片**。修法是 `Alignment.BottomEnd`（本来就在）+ 新 token **`MENU_TRIGGER_INSET = 8`** 的**负**偏移（内收）。新几何：圆片/点击盒的右下都在封面内 8 vp，圆片底边在书名首行之上净空 14 vp。**锚点是封面的角本身，所以任何卡片宽度下都成立**。**点击目标没有缩水**：`MENU_TRIGGER_TOUCH` 仍是 **48 vp**，仍由**盒子**接点击（31→32 vp 的圆片只负责好看）；菜单锚在同一个盒子上，`BottomRight` + `MENU_TRIGGER_GAP = 8` 一字未动，所以菜单跟着整体上移左移 8 vp、相对关系不变。

**② 书名单行省略，行高回归一致（这是实测出来的副作用，而且推翻了本轮自己的简报）。** 同一份 dump 的 9 个 cell：**8 个书名是一行 47 px，只有 `斗罗大陆2绝世唐门足交传说` 是两行 94 px**；它的行高因此变成 **683 px**，另外两行是 **636 / 637 px**。分解：封面 539 + 间隙 20 + 书名 47 + 间隙 20 + 进度条 10 = **636**，多出来的正好是那**一行** 47 px（行高由该行最高的 cell 决定）。所以 `maxLines(1)` 之后**每一行都是 636 px**，而且是**那一个高行降回 636，不是其他行涨到 683**——简报里「应该变成 tall-but-uniform 的那个值」这个猜测**与实测相反**，实测的一致值是 **636**。顺带把 `.fontSize(12)` 换成 `TYPE_CAPTION`（值不变，变的是它现在是比例尺上的一档），并**补上 `.fontColor(this.palette.foreground)`**——不设它就会跟随**系统**色彩模式（系统深色 + 应用护眼时会画出近白的字压在暖色页面上）；`.width('100%')` 保留，否则 `TextOverflow` 静默失效。

**③ 无封面占位：从「一个字」改成「完整书名」，28 fp → 24 fp。** `PLACEHOLDER_TITLE_SIZE = 24` + `PLACEHOLDER_TITLE_LINES = 5` + `padding(SPACE_XS)` + `textAlign(Center)` + `clip(true)`。**为什么是 24 而不是更小**：那一对颜色的护眼比值 3.916:1 靠的是**大字号豁免**，而豁免是关于字号的——24 fp 是该 token 还能移动、又不把调色板一起拖下水的**最小值**。**容量用 dump 实测的行盒比例算**（12 fp = 1.161 em，28 fp = 1.175 em，取大者），得到 **每行 4 字 × 5 行 = 20 个汉字**，容得下本轮出现过的每个书名（最长 13 字）。**封面盒不会变形**：`width('100%')` + `aspectRatio(0.7)` 的高度由宽度推出、与子节点无关，`maxLines` 封住**测量**高度、`clip(true)` 封住**绘制**。

**审计**：30 工具 / **3621** 项 / 3621 通过 / 0 失败（基线 3599 → 净 **+22**：`verify-book-menu` 165 → **184**、`verify-themes` 203 → **206**，其余 28 个工具逐项相等）。`verify-book-menu` **改判 2 条**（都是被设计变更强制反转的）：「圆片用 offset 位移」的锚点改成内向偏移，并**新增**一条把旧的向外位移按值断言为**不存在**；原「圆片小、点按目标是 48」一条拆成两条并**从 token 读数值**，另新增「可见圆片不超过自己的点击盒」——它才是「点击盒在封面内 ⇒ 圆片在封面内」那一步推理的前提。**新增 17 条**：几何输入全部定位（缺一个就大声失败）、**containment 算术**（用 320/380/391.1/600/840/1024 vp 六个宽度按 `shelfColumnsForWidth` 自己的断点重新推导列数与卡片宽，断言 `inset + touch ≤ 卡片宽`；最紧的是 380 vp / 3 列 / 108.0 vp，余量 52.0 vp）、内向符号、以及新的一节「cell 的两个书名」。`.diag/r114-mutate.mjs`：**27/27 全部被抓、0 条 NOT APPLIED**、四个源文件逐字节还原；其中两条是刻意设计的——**「删掉 `.maxLines(1)`」能抓住，是因为该属性上面的注释里就写着 `.maxLines(1)`**，所以切片必须从**去注释后的源码**上取（这条教训 r115/r116 各命中过一次）。`.diag/r114-verify.ps1` + `.diag/r114-layout.mjs` 是**被动**验收脚本（不注入任何手势），并**已用 r108 那份旧 dump 反过来验过**：它正确报出 `683 / 636 / 637 -> NOT UNIFORM`、`chip bottom is 54 px BELOW the cover's bottom edge`、`chip overlaps the caption's line by 34 px`。

**未验（不许当成已验）**：设备全程 `Offline`，所以**本轮没有一个新数字是在装好的 r114 上量到的**——「改完以后」全是算术加上 r108 那份 dump 的实测基线。必须装机核对：圆片底边真的在封面内 8 vp、书名真的都单行且省略号真的渲染出来、每一行真的都是 636 px、占位真的显示完整书名且没有撑高封面盒、三个主题下的对比与几何。

### r113：删除 r110 的阅读器入场滑入，只保留主题同色的加载界面（**已完成构建与审计，未装机验收**）

**用户装完 r112 后说**：「现在不会黑了，是和主题相同的颜色。我觉得现在可以把滑入去掉了，就保留这个和主题同色的加载界面」。所以本轮**只有一件事：把 r110 的「从右滑入」整个删掉**。**纯删除，`Index.ets` 一个文件，+24/−194。**

**删之前逐个查过每个入场符号的读者数，确认没有任何符号在入场之外还有读者**（`READER_ENTRY_OFFSET` / `_RESPONSE` / `_DAMPING` / `_DURATION_MS` 各 1 个读者、`@State readerEntered` 9 处、`readerEntryTimer` 8 处、`startReaderEntry()` 2 个真调用、frame 上的 `.translate`/`.opacity`/`.onAppear`、整个 `aboutToDisappear()`——它的方法体**只有**入场拆除、以及只被那一条 `springMotion` 用到的 `curves` import）。特意核对过两处**看起来**可能共用的：`animationOn` 有 4 个读者（**保留并钉住计数**）；`springMotion` 在 `ReaderView.ets` 里是**另一套**（`BAR_SLIDE_*` + `(0.45, 0.85)`），**一个字没动**，还新加一条断言钉住它四个常量都还在。

**最值钱的一条结论**：**`onAppear` + `setTimeout` 那层延迟，本来只是为了给 `animateTo` 一个「from」值**（`readerEntered` 初值 `false` 就是那个起始态，而起始态要等组件存在之后才有值可插值）。起始态没了就**没有任何东西需要延迟**——**`Index.ets` 现在整份文件一个 `animateTo` 都没有、一个 `.onAppear` 都没有**（页签动效是 HDS 的，由 `tabSwitchDuration` 配置，不在这里跑）。这条作为断言固化，**而且是对去注释后的源码断言**，所以解释文字可以照常提到那两个 API。

**审计**：30 工具 / **3599** 项 / 3599 通过 / 0 失败（基线 3604 → **净 −5**，全部在 `verify-motion` **153 → 148**）。r110 给入场加的 **19** 条断言（简报写 16，实测 19）逐条处理：**13 条删除**（它们守护的东西已不存在）、**3 条保留并加强**、**3 条改指向浮动栏**——改指向的**更强**：作用域从入场那几行放大到**整个 `ReaderView.ets`**，闭集改成**精确多重集相等**（`scale`/`rotate`/`visibility` 这些别的切片看不见的第四种属性在这里会失败）。另加**阴性断言**（四个入场标识符按**裸 token** 断言不存在，外加 frame 属性链的**精确集合** `[backgroundColor, height, width]`——比否定式强，因为它是对渲染树的**正面**陈述）。`.diag/r113-mutate.mjs`：**23/23 全部按预期行事**（21 条必须被抓，其中 20 条必须被**指定的那一条**抓到；1 条 control 必须保持全绿——把 `duration: 0` 只写进注释，证明那条阴性读的是**代码**不是散文）。

**未验（不许当成已验）**：本轮**没有装机验收**（设备是 `Connected`，但这是纯删除、不需要设备，且规则禁止在用户使用中注入手势）。「点书后完全没有滑动、直接是 `正在排版...` 封面、然后第一页，无黑无闪」以及「两栏显隐动画照常」是**待验**。



### r112：黑帧的真因不是「kit 面板盖住 ArkUI」，而是 `loading` 早落一帧（**已完成构建与审计；真机逐帧证据齐全，但修复未经装机验收**）

**用户原话**：「现在滑动特效有了，但是还是会有黑帧」。**r111 的判断被真机逐帧否掉了，别再照它推导。**

**测量方法（可复用，别重新发明）**：`snapshot_display` **无论输出尺寸都固定约 330 ms/帧**（`-w/-h` 试过 330/660/1320，几乎无差别），这是硬地板。所以单次开卷很容易整帧跳过黑帧。**做法是重复冷启动开卷 + 每卷一次连拍 + 每卷一份 `hilog -x`**；帧与日志走同一系统时钟（`date +%s%3N`），可以互相对齐。`.diag/r112/opens.sh` 就是这套脚本（16 次开卷约 2.5 分钟）。

**16 次冷启动开卷的结论**：
- **128 帧里只有 1 帧是黑的**，而且**紧挨着第一张正文页**。按 330 ms 的采样地板，**16 次才中 1 次** → **黑帧只宽一帧（约 16 ms）**。**r111 声称的「12/12」不可能是这一帧，那个数字不要再引用。**
- 那一帧实测 **99.7% 纯黑、中心区一点墨迹都没有**（没有 spinner、没有 `正在排版...`）。
- **它的前一帧就是封面本身**：spinner + `正在排版...` 画在页面底色上 —— 所以 **ArkUI 的 `Column` 确实画在 kit 面板之上**：r111 的前提对、结论错。
- 黑帧那一下**封面已经撤掉了**（否则中心会有墨迹）。根因是 `initialize()` 的时序洞：**`loading` 在 `await startPlay` 返回时立刻落 false，而 kit 要到下一帧才把刚排好的页合成上屏** → 这一帧封面没了、kit 面板还是空的。

**kit 面板是什么（日志即声明）**：`OnSurfaceCreatedCB` / `InteractiveNapi::OnSurfaceCreated` / `[OpenGL]: Init w = 1320, h = 2848` / `EglWrapperHookLayer init Failed!` —— 它是**自绘制的 EGL Surface**，覆盖整屏。EGL surface 创建时清成黑色，这解释了为什么是纯 `rgb(0,0,0)` 而不是暗色主题的 `rgb(18,18,18)`。官方文档（MCP 可查）：**自绘制组件内容透明时，露出来的是该组件自己的 `backgroundColor`**。这是 r112 给 `ReadPageComponent` 加底色 backdrop 的依据。

**r112 的修法**（两处，`ReaderView.ets`）：
1. **封面活过 `loading`**：新增 `@State firstPageShown`（**独立旗标**，`loading` 语义一字未动，四个 `if (this.loading) { return; }` 守卫照旧），封面条件是 `if (this.loading || !this.firstPageShown)`，在**第一个 `PAGE_ON_SHOW`** 置位；另有 `FIRST_PAGE_GRACE_MS = 1200` 的 **fail-open 定时器**（`pageShow` 不来也不会把读者锁死在封面上）。
2. **`ReadPageComponent` 自带页面底色** `.backgroundColor(this.pageBackground())` —— 第二道防线。

**留了三条日志当量尺**（`InkBoatReader` 标签，与帧同一时钟）：`reader cover: startPlay resolved, cover held until the first page` / `reader cover: first page shown, cover lifted` / `reader cover: no first page within %dms, lifting anyway`。**以后要定位黑帧，就靠这三条 + 连拍对齐。**

**审计**：30 工具 / **3604** 项 / 3604 通过 / 0 失败（基线 3601 → 净 **+3**，全部在 `verify-reader-chrome`：399 → **402**；`verify-book-menu` 的 BUILD_STAMP 正则从 r111 改到 r112，条数 165 不变）。`.diag/r112-mutate.mjs`：**13/13 全被抓、0 条 NOT APPLIED**（锚点唯一性先证明再替换）。`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块 / 31 个标记**，锚点行号移到 **4548/4572**。

**未验（不许当成已验）**：**本轮修复没有装机验收** —— 设备在测量途中掉线（`list targets` 变 `Offline`），r112 的 HAP 用户还没装。「黑帧是否真的消失」是**待验**，不是已完成。

### r107：shell 状态栏常显 + 底栏避让导航条 + 标题下移与内容压缩（**已完成构建与审计，待装机验收；r107 无设备连接，真机数据一个都没有**）

**用户的四条要求（原话）**：「主界面的底栏也要避开导航条」/「信号栏在主界面应该是常显的，现在隐藏了」/「标题要下移，现在是和挖孔在同一个高度，标题下移那下面的内容也要跟着压缩，先这样改」/「阅读界面暂时就这样」。

**① 一个测量，两处用。** 全屏布局（`setWindowLayoutFullScreen(true)`）的官方语义是**「布局不避让状态栏与导航栏，组件可能与状态栏、导航栏重叠」**，所以 shell 必须自己避让；官方沉浸式指南的全屏样例就是**读 `getWindowAvoidArea` 再 `padding`**（否则「UI元素就会发生重叠」）。`Index.resolveShellInsets()` 在 `aboutToAppear` 读一次，得到 `shellTopInsetVp`（=39）与 `shellBottomInsetVp`（=28），两者都是 `@State`（异步 promise 在首帧之后才回来，普通字段永远不会更新）。**三读两块**：`TYPE_CUTOUT`（@since 7）与 `TYPE_NAVIGATION_INDICATOR`（@since 11）用普通读法；`TYPE_SYSTEM` 用**与可见性无关**的 `getWindowAvoidAreaIgnoringVisibility` + `canIUse('SystemCapability.Window.SessionManager')` 守卫 + 旧读法回退（理由：这个读法在 `aboutToAppear` 里与「显示状态栏」的写入竞争，而它要的是**band** 而不是当前画没画；顺带两个文件同一条规则）。`Math.ceil` 向上取整，`Math.max(cutout, status)` 取高者。**这条读法与 `ReaderView.resolveAvoidInsets` 是刻意的重复**，因为本轮**不许动阅读器**。

**② 状态栏基线 `false` → `true`，且必须两处一起改。** `Index.applySystemAppearance()` 现在写 `('status', true)`；`ReaderView.aboutToDisappear()` 是「恢复 app 级基线」，因此**同步改成 `applyReaderStatusBar(true)`**。**留在 `false` 就会「关掉书就把 shell 的信号栏按掉」**——用户下一步必然报的那个 bug。`verify-reader-chrome` 新增一条**跨文件取值相等**断言（提取两个文件里的字面量比大小），单文件怎么读都看不出来。`toggleBars` 一字未动。
- **诚实披露的一处行为漂移**：阅读器只在「切两栏」和「卸载」时写状态栏，**挂载时继承 shell 的可见基线**，所以刚打开书（两栏未动）时会看到信号栏，第一次切两栏之后才与 r106 完全一致。本轮**被授权只改卸载那一个值**，所以没有加挂载写入；补救是 `aboutToAppear` 里加一行 `applyReaderStatusBar(false)`（会变成第三个调用点，要连带改写「恰好两个调用点」那条断言）。**已在 `applyReaderStatusBar` 的文档里记录。**

**③ 底栏避让：`barBottomMargin = FLOATING_BAR_BOTTOM_MARGIN + shellBottomInsetVp`（8+28=36vp），仍是带单位字符串。** 自查发现**还有一处必须一起动**：`FLOATING_BAR_CLEARANCE`(96) **恰好就是栏的绘制盒**（8 边距 + 56 胶囊 + 32 渐变蒙层 = 96），内容按它 padding 后正好停在蒙层起点。胶囊抬高 28vp，**蒙层跟着抬高**，所以两个真正在栏下方的滚动拥有者（`ShelfPage` 的 Grid、`AnnotationsPage` 的 List）改成 `FLOATING_BAR_CLEARANCE + this.bottomInsetVp`（96→124，新增 `@Prop bottomInsetVp`），否则**列表最后一行会落在蒙层里、看起来是淡掉的**。**`syncSection` 刻意不动**（它在被 push 的 `NavDestination` 里，整个盖住浮栏）；**`settingsList` 也刻意不动**（两行高，用 `SPACE_M`，原有理由仍成立）。

**④ 标题下移 + 内容压缩：一个 padding。** `pageTitle` 与 `detailHeader` 的 `top` 改成 `this.shellTopInsetVp + SPACE_S`（39+8=47vp），**三个 tab 共用同一个 builder，所以一次改完**；`detailHeader`（主题/同步两个被 push 的页面）一起改，因为用户说「我以书架为例」而它们同处一个 band。**压缩是结构自带的**：每个 section 是 `height('100%')` 的 `Column`，上面是**不加权**的标题 `Row`、下面是 `layoutWeight(1)` 的 `Scroll`/`List`/`Grid`，标题长高多少，加权子节点就少多少——**不会把内容顶出屏幕**，也不需要任何测量。

**审计**：30 工具 / **3580** 项 / 3580 通过 / 0 失败（基线 3553 → 净 **+27**，**全部在 `verify-reader-chrome`：371 → 398**；`verify-book-menu` 164、`verify-objective-coverage` 225 是**改写在位**，条数不变）。新增/改写的断言：shell 的三读两块与取整规则、两个 `@State` 字段、读一次、**top inset 恰好 4 个读者 / bottom 恰好 5 个读者**、标题与 detailHeader 的 padding、**三个 section「无权重标题 + 权重滚动」**、**section 不许再自己加 inset**、`barBottomMargin` 的带单位组合、**`clearance === 56 + margin + mask` 的数值恒等式**、两个子页面接收 inset、sync 页刻意不加、**跨文件状态栏取值相等**、日志按调用形态命名路径。`.diag/r107-mutate.mjs`：**36/36 全被抓**（逐条打印触发它的断言标签；第一轮跑出 5 条 `NOT APPLIED`，根因是**源码是 CRLF**，多行锚点写成 `\n` 就没匹配上——变异脚本已修，那条 `NOT APPLIED` 报告本身也留在输出里）。`.diag/r107-strip-check.mjs`：探针在场/剥离两变体跑 5 个工具**全绿**（398/225/203/164/134），剥离后源码按字节还原，两变体的 shell 取值都读出 `true`/`true`。`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块 / 31 个标记**，行号移到 **492/792/889/3587/3621/3652/3758/4399/4423**。

**未验（不许当成已验）**：**本轮全程没有设备**（`hdc list targets -v` = `[Empty] hdc`），所以真机上一个数字都没测：shell 是否真的常显信号栏、标题首行墨迹是否真的约 159px、胶囊底边是否真的离屏底约 121px、列表最后一行是否真的不再落进蒙层、阅读器挂载时那处漂移看起来如何、`shell insets` 日志报的是不是 `cutout 120 / status 131 / top 39 / bottom 28`（`getWindowAvoidAreaIgnoringVisibility` 的 syscap 声明 ≠ 执行结果）。`.diag/r107-capture.ps1` 就是为这六件事写的（缺设备时 `STOP: no Connected target` + exit 2，**不注入手势**）。

### r106：去掉常驻章节名 + 状态栏跟随两栏显隐（**已完成构建与审计，待装机验收**）

**① 常驻章节名只能删、不能移（最贵的一条结论，别再重新推导）**

用户想要「章节名贴在纸上、跟着翻页转」。**做不到**，三条独立证据：① **翻页动画由 kit 进程内的 `flip_SimulationPageAnim` 画在 `ReadPageComponent` 节点内部**，应用在页面 `Stack` 里加的兄弟节点只是「更晚的兄弟」，画在它**上面**，永远不会被翻页带走；② **没有内容注入点**——`pageHeaderContent`/`pageFooterContent` 官方标注**「预留字段，暂不支持。」**，`ReaderSetting` 恰恰 13 个字段（无 padding/inset/margin/safeArea），`flipMode` 只有 `'0'`/`'1'` 两值；③ **「发灰」不是层级问题**——静态帧正文墨色实测**纯 (0,0,0)**、标题墨色亮度 **80–87**，正是 `chromeMuted()` 在页面上合成的 **(78,78,77)**，它**本来就是淡的**。

**删掉**：`chapterOverlay()`、`chapterOverlayVisible()`、`persistentTitleAnchorVp()`、`PERSISTENT_TITLE_LEFT`(27)、`PERSISTENT_TITLE_RIGHT` 及 `build()` 里的调用点。**不变量的新形式（更强）**：原来是「同时只有一个章节名」，靠 `!topBarVisible()` 让两个绘制点互斥；**现在是一个计数**——`Text(this.chapterTitle)` 全文件**恰好 1 处**（`topBarRow` 内），且那 5 个符号一个都不许回来。计数比否定式强：否定式只能对它已知的两个面推理。`topInsetVp` 读者 4 → 3。`chapterOverlay` 是 `position` 兄弟覆盖层，删它**不可能**改被测量盒。

**② 状态栏跟随两栏显隐**

- **测量修正**：brief 里的 **195 px / 57.8 vp 是错的**。`hidumper -s WindowManagerService -a '-a'` 打的是 `SCBStatusBar22 [ 0 0 2848 131 ]` → **131 px = 38.8 vp**（WM 按**自然/横向**帧打矩形）；手势条 `SCBGestureNavBar14 [ 0 1226 2848 94 ]` → 94 px。**独立佐证**：sheet 顶边实测 **1488 px**，131 px 基准内缩预测 1489.5 px，195 px 预测 1521.5 px。**所以 `topInsetVp` 36 → 39，不是 58**；胶囊顶边 136 → **145 px**。
- **读法必须与可见性无关**：`getWindowAvoidArea` 尊重 `AvoidArea.visible`，状态栏隐藏时 `TYPE_SYSTEM` 报 0。用 **`getWindowAvoidAreaIgnoringVisibility`**（`@ohos.window.d.ts:4243-4277`，`@since 22`）。它**同时是 `@syscap SystemCapability.Window.SessionManager`**（旁边三个读是 `...WindowManager.Core`）并声明 `801` → **要 `canIUse` syscap 守卫 + 回退到旧读法**；API 级别不用守（22 ≤ 24）。
- **该设备有这个能力（已实测，不再是悬案）**：`/system/etc/syscap.json` 的 `window_manager` 组件同时声明两者（已拉到 `.diag/syscap.json`）。**回退分支在真机上没被执行过。**
- **三个调用点**：`Index.applySystemAppearance()`（app 级基线，**未动**）· `toggleBars()`（`applyReaderStatusBar(this.barsVisible, true)`，在 `if/else` **之后**、`animateTo` **之外**）· `aboutToDisappear()`（`applyReaderStatusBar(false)`，**无条件**，唯一卸载路径）。`enableAnimation`（@since 12）传 `true`：应用无法把 `springMotion` 交给系统栏，**让信号栏贴着弹入的胶囊「硬切」更难看**。
- **`toggleBars` 的 `if` 极性翻转**：`if (!animationOn){apply();return;}` + 尾部 `animateTo` → `if (animationOn){animateTo} else {apply}` + 尾部状态栏写入。**早返回让「两条路径共用一个尾部」不可能**，而状态栏两条路径都要写。门、跳过 `animateTo`、唯一赋值点未变；两条断言改写成等价或更强（新增「`duration: 0` 不许出现」）。
- **不同步风险（已记录，未发生）**：状态栏只有两个写者且生命周期不相交——`applySystemAppearance` 跑在启动/换主题，而**主题选择器在 shell 的「设置」页**、阅读器**替换** shell、其设置 sheet**只有字号**。**残余风险**：将来若给阅读器 sheet 加主题控件，那次切换会在 `barsVisible` 为 true 时按掉状态栏；补救是「阅读器在宿主写入后重新声明」，**不是第三个写者**。
- **不要接 `on('avoidAreaChange')`**：其触发场景是全屏/悬浮/分屏切换、旋转、折叠展开、跨设备迁移——**状态栏显隐不在其中**。

**③ 文字上边界能否上移到顶栏上沿 —— 结论：做不到，已按用户授权放弃，一行代码没写**

- **页面盒顶边就在 `y = 0`**（无偏移可回收）。四条独立证据：① `ReaderView` 根 `Column`、`Index.readerScreen` 的 `Column`、`Index.build` 根 `Column` **都无 padding/margin**；② 窗口 `setWindowLayoutFullScreen(true)`（布局**不**避让状态栏）；③ **设备算术**：`topInsetVp`=36 时胶囊顶边实测 **136 px** = 36+4 vp，若盒子被挖孔顶下去读数会是 243 px；④ 运行中的 kit 日志 `drawAnim: offsetY is -843.8518518518518` = **整屏高**（2848/3.375）= kit 的页面盒就是整屏。
- **杠杆逐个排除**：`ReaderSetting` 13 字段无 inset；`setPageConfig` 只吃字体度量 + `viewPortWidth/Height`；页面盒**位置已是 0**、**尺寸**改了就是重新分页（用户硬约束）；`expandSafeArea` 只能扩到安全区，0 以上没有东西；`"avoid_cutout"` metadata **被禁止**（移动整页）；`ReadPageComponent` 只声明 `controller`/`readerCallback` + `build()`，**无任何内缩属性**。
- **kit 的 68 vp 是它自己算的、且随盒子放大**：设备日志 `paddingTop` 在 box 604.7→843.85 vp 间取 **68 / 72.17 / 79.63 / 92**（≈盒高 10.7–11.25%），**不是可配置常量**；官方 FAQ verbatim：**「阅读页组件顶部和底部预留了页眉页脚，呈现效果为顶部和底部有空白。」** kit 还会把排版盒**缩放到组件真实尺寸**，所以改 `viewPortHeight` 动的是**缩放比**（字号与一页容量），不会把文字顶上去 = 改变显示范围，被禁止。
- **诚实的近失**：给 `ReadPageComponent` 挂 `.offset({ y: -32 })` 能整页**平移**上去，但会把最后一行推出屏幕底边（丢内容、改变显示范围），且**没有**改变文字相对自己页面的上边界 —— 不是杠杆，是违规，没做。
- **结论**：文字上边界 = 页面盒顶(0) + kit 的保留页眉（当前配置 68 vp，加行距留白后首行墨迹 **329 px = 97.5 vp**）。**顶栏上沿是 36 vp（本轮后 39 vp），中间那段是 kit 的。** 唯一「更近」的是调小字号——它改变一页装多少字，**不改变从哪开始**。

**审计**：30 工具 / **3553** 项 / 3553 通过 / 0 失败（基线 3548 → 净 **+5**：`verify-reader-chrome` 368 → **371**，`verify-objective-coverage` 223 → **225**）。`.diag/r106-mutate.mjs`：**25/25 全被抓**（逐条打印触发它的断言标签）。`.diag/r106-strip-check.mjs`：探针在场/剥离两变体都跑审计（371/225/203/164/134 全绿），剥离后源码按字节还原。`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块**、标记数 31、行号移到 492/792/889/3558/3592/3623/3729/4370/4394。

**未验（不许当成已验）**：状态栏真机上是否真的随两栏显隐、系统给它什么曲线、`getWindowAvoidAreaIgnoringVisibility` **真实执行**时是否报 131 px（syscap 声明 ≠ 执行结果）、胶囊顶边 145 px。`.diag/r106-capture.ps1` 就是为这四件事写的（缺设备时 `STOP: no Connected target` + exit 2）。

### r102：顶栏避让挖孔 + 两栏同宽 + 底栏避让导航条（**已完成构建与审计，待装机验收**）

**用户看着装好的 r101 提的三条**，以及一条把实现方式钉死的追加约束：
「顶栏直接顶着屏幕最上面，但屏幕上还有前置摄像头挖孔，我想让顶栏在挖孔的下面」/「顶栏的宽度就和底栏一样就够了」/「底栏要稍微上移一点，避让系统导航条」/ **「文字的显示范围保持这样不变就行了」**。

**① 挖孔有 API，而且早就有。** `window.AvoidAreaType.TYPE_CUTOUT`（`= 1`，**`@since 7`**）就是挖孔；`getWindowAvoidArea(type)` **本身就是同步的、返回 px**——**SDK 里没有 `getWindowAvoidAreaSync`**（找过了），也没有 vp 版本重载，所以 px→vp 必须自己做（`this.getUIContext().px2vp`）。`AvoidArea` = `visible` + `leftRect`/`topRect`/`rightRect`/`bottomRect`，`interface Rect` 明写 "in px. The value must be an integer"。顶部挖孔经 `topRect` 上报（官方 `immersive-window-feature` 的 `handleCutoutAvoidArea` 就是这个形状）。

| 成员 | 值 | `@since` | 本屏用途 |
|---|---|---|---|
| `TYPE_SYSTEM` | 0 | **7** | 状态栏带；挖孔的**文档化代理**（`window-faqs`：主窗口全屏时可取到「包含状态栏的避让区域」） |
| `TYPE_CUTOUT` | 1 | **7** | 挖孔本身；顶栏就该避让它 |
| `TYPE_SYSTEM_GESTURE` | 2 | 9 | 侧返回手势（**「Currently, no devices support this type」**） |
| `TYPE_KEYBOARD` | 3 | 9 | 软键盘 |
| `TYPE_NAVIGATION_INDICATOR` | 4 | 11 | **底部手势导航条**（本机 94 px = 27.9 vp） |
| `TYPE_FLOAT_NAVIGATION` | 5 | **26.0.0** | 悬浮导航——**唯一需要守卫的成员，本项目不读它** |

- **三个用到的成员全都 ≤ 11，远低于 `compatibleSdkVersion` 24 → 不需要 `apiLevel` 守卫**（和 `ImmersiveMaterial` @26.0.0 的情形正相反；那种才要 `canApplyImmersiveMaterial()`）。
- 顶部 inset = **`max(挖孔, 状态栏带)`**（官方样例就是 `Math.max`）——挖孔通常**在**状态栏带之内，取大者两个都避开；每个带取 **`top + height`**（`Rect` 不保证 `top = 0`），底部带取 `height`。**px→vp 结果向上取整**（195/3.375 = 57.78 → 58 vp）：避让是余量，不能短一点，而且整数才是 `%{public}d` 和验收脚本读得回的形式。
- **值不是活的**：只读一次（`aboutToAppear`）。`on('avoidAreaChange')` 是变活的那条路，本轮**刻意没接**（旋转会走测量盒重排，横屏挖孔上报在**左**边，是另一个 inset）。**两条原始 px 值都打日志**（`avoid areas: cutout top … px, status bar top … px, gesture bar … px -> top inset … vp, bottom inset … vp`）——**真机上这两个值本轮没测到**，日志就是拿到它的方式。
- **绝对不要加 `module.json5` 的 `"avoid_cutout": "true"` metadata**：那会让**整页**默认避让挖孔 = 文字下移，正撞用户「文字范围不许变」的约束。避让必须只加在栏上。

**② 两栏同宽：一个常量，两处读。** `Theme.FLOATING_BAR_WIDTH = 328`，依据是设计规范自己写的 `HdsTabs.barWidth` 默认值：「页签个数大于等于4时，页签栏**最大宽度不超过 328vp**」（≤3 个才是 `76vp×n+8vp`）。`HdsBarWidthRangeOptions` 声明里**没有任何数字默认值**，只有「哪档对应哪个宽度区间」。
- 顶栏胶囊：`width('100%')` + 左右 `FLOATING_BAR_SIDE_MARGIN`（= 359 vp，用户嫌宽）→ **`.width(FLOATING_BAR_WIDTH)`，margin 删掉**（留着就是「328 的宽度又内缩 16」，两栏差 32vp）。外层 Column 显式 `.alignItems(HorizontalAlign.Center)`（默认就是 Center，但窄胶囊靠默认对齐是隐患）。
- 底栏：`barFloatingStyle.barWidth = { smallWidth/mediumWidth/largeWidth: '328vp' }` **三档全钉**，宽度不随断点变。`Length` 一律**带单位字符串**（和两个 margin 同理，HDS 用单位解析器，裸数字静默丢弃）。

**③ 底栏避让导航条：加在胶囊的 anchor 上，箱体同步长高。**
- `bottomBarMarginVp() = FLOATING_BAR_BOTTOM_MARGIN + bottomInsetVp`（8 + 28 = 36 vp），**仍是带单位字符串**（`` `${this.bottomBarMarginVp()}vp` ``）。
- `bottomBarBoxHeight() = BOTTOM_BAR_BOX_HEIGHT + bottomInsetVp`（120 → 148 vp）。**必须一起长**：胶囊抬高多少，箱内就多多少被绘制的内容（渐变蒙层仍要够到屏幕底边），不长就会出现 r101 那种「被截断」。
- **代价（就是 tap-eating band 变大）**：箱体高度**就是**栏显示时归栏的那条带 → 120 → 148 vp。栏隐藏是 `Visibility.None`（不可命中），所以**常态代价为 0**。

**④ 「文字范围不变」是结构性断言，不是承诺。** 两个 inset **只**出现在三个地方（顶栏 `position`、`bottomBarMarginVp`、`bottomBarBoxHeight`），**`build()` 的元素树里一次都不出现**（页面层就画在里面）；`resolveViewPort()` 与 `toKitSettings()` 里也没有 `Inset`；页面层自己的属性链仍然**只有 `.width('100%')` / `.height('100%')` / `.onAreaChange`**。四条断言守着，其中「实现成页面 padding」的变异被 3 条同时抓到。

**审计**：30 工具 / **3524** 项 / 3524 通过 / 0 失败（`verify-reader-chrome` **322 → 344**，新增 22 条，**改了 5 条**：顶栏 `position` 的 top 由字面量 0 改成 `this.topInsetVp`；胶囊 margin 计数 → 共享宽度计数（另加「margin 必须不在」）；`barBottomMargin` 的单位断言改成组合形式；箱体 `.height` 改成 `bottomBarBoxHeight()`；`FLOATING_BAR_BOTTOM_MARGIN` 的旧字符串断言改成「设计值 + 活 inset」。**全部等价或更强**）。`.diag/r102-mutate.mjs`：**22/22 全被抓**。`.diag/strip-sheet-probe.mjs` 仍可用：**9 个块**，行号移到 354/654/751/3174/3208/3239/3345/3983/4007（内容是标记锚定，不是行号）；**探针剥离后的变体也跑过审计（344/203/223 全绿）**。

**未确定**：真机上 `TYPE_CUTOUT` / `TYPE_SYSTEM` 到底报多少 px **没测**（设备被用户占用，且规则禁止在其使用中注入手势）——**若日志里两个都读 0，顶栏就还在 r101 的位置**，那时才需要一个实测常量（脚本 `.diag/r102-capture.ps1` 会把日志行和两栏实测宽度一起打出来）。**底栏实际渲染宽度**同样没测；把 `barWidth` 钉死为 328 之后它由常量决定，但「HDS 原本是不是也 328」只有装机后量两栏宽度才能确认。

### r100：阅读器浮动两栏 + 三分区点击覆盖层（**已完成构建与审计，待装机验收**）

**这一轮把「当前主线」做完了**：旧顶栏、旧底栏（含进度行）和材质探针**全部删除**，换成两条**常态隐藏的浮动栏** + 一个**三分区点击覆盖层**。

**顶栏**：`Navigation` 标题栏（**唯一能承载 `systemMaterial` 的两条路径之一**）+ `BarStyle.STACK` + `hideBackButton(true)` + `expandSafeArea([], [])`，内容栏里是 `topBarTitle()`（材质容器，`ULTRA_THIN`）/ `topBarRow()`（返回 · 章节名 · 页码）。**没有 `Navigation` 属性形式的 `barStyle`**——它只在 `NavigationTitleOptions` 里（`navigation.d.ts:2324` 只有一个 `title(value, options?)` 重载）。
- **API 26 守卫**：`uiMaterial.ImmersiveMaterial` 是 `@since 26.0.0`，所以 `topBarTitle()` **分两支**（有材质 / 无材质画 `pageBackground()`），由 `Theme.topBarMaterialOption()` 决定——它复用既有的 `materialOption()`（即 `canApplyImmersiveMaterial()`，读 `deviceInfo.sdkApiVersion`）。**API-24 设备看到的是一个不透明的顶栏**，元素一个不少。编译器会对这一行报与 `ShelfPage:509` 相同的 "compatible SDK version 6.1.1(24)" 警告，**这是预期的**（项目既有的物料守卫就是运行时的）。
- **`渐变模糊` 刻意没做**：官方功耗指南明确「材质的 `materialFilter` 已含背景模糊，再叠加属重复处理」，且 `Navigation` 标题栏没有渐变蒙层参数。
- **`expandSafeArea([], [])` 是必需的**：`Navigation` 默认扩展安全区，而 `position` 与它同设时**先 position 后 expand**（`common.d.ts:17239`），留着默认会让这个 56vp 浮层画到自己被测的盒子之外。

**底栏**：`HdsTabs` + **四个真 `TabContent`**（各带 `BottomTabBarStyle`），`barFloatingStyle` + `barOverlap(true)` + `vertical(false)` + `barPosition(End)` 四条件齐全，边距是**带单位字符串**，材质 `IMMERSIVE`/`ADAPTIVE`（= 悬浮底栏的系统默认 `THIN`）+ `gradientMask.maskColor = pageBackground()`（= 设计规范的「渐变颜色蒙层」）。`index: 0` 固定 + `onContentWillChange` 返回 `false`，派发在 `onTabBarClick`。**格子高度靠 `FLOATING_BAR_CLEARANCE`（96vp）**，与 shell 的浮栏同一套数字。

**两条栏都是 `position` 定位的「覆盖层」**（`{left:0,top:0}` / `{left:0,bottom:0}`），画在**页面 `Stack` 之内**：

```
Column
└ Stack(覆盖层)                      ← 尺寸来自 layoutWeight，不来自子节点
  ├ Stack(页面层)  ← 唯一被 onAreaChange 测量的盒子；.foregroundBlurStyle 挂在这里
  ├ 提示 chip（浮层，Transparent）
  ├ tapZones()    ← HitTestMode.Transparent，三列 layoutWeight(1)
  ├ topBar()      ← 在分区「之上」，所以栏内点击归栏
  └ bottomBar()
```

**遮挡/代价（如实记录）**：栏显示时，底栏那 96vp 的 `Tabs` 盒子里的点击归栏（翻页点击在那一条带上无效）；栏隐藏时是 `Visibility.None`（**不可命中**），代价为零。

**为什么这样就不会再「重新分页」**：栏是页面 `Stack` 的**兄弟覆盖层**，页面层的尺寸由 `layoutWeight(1)` 决定、与任何子节点无关 → 栏的显隐**根本不是一次布局事件**。断言它是**结构**（两条栏都在页面 Stack 内、都带 `position`、`onAreaChange` 全文件只有一处），不是承诺。顺带把 toast 也移进了浮层（它现在没有调用者，但以后有了也不会再改盒子）。

**审计基线**：**30 工具 / 3459 项 / 3459 通过 / 0 失败**（材质探针删除后，r99 的那两条失败如预期消失）。本轮改的断言见 §9 末尾。

**真机未验的部分**（明确列出，不要当成已验）：`Navigation` 无内容时标题栏是否正好 56vp；标题栏材质在真机上是否可见；底栏 96vp 盒子里四个格子与材质的渲染；栏显示时左右点击是否仍翻页；**滑动在 r100 结构下没有重量过**（r99 之前测的是探针版覆盖层）。

### 四个 sheet 的重做（已完成，护眼主题下已验收）

**改动**：四个 sheet（目录/书签/笔记/设置）共用**一个表头**（`@Builder sheetHeader(title)`：大标题 + 右上角圆形 ×），**`height: '50%'` 半高**，`backgroundColor: this.sheetCard()` + `dragBar: false` + `showClose: false`；书签/笔记改成**居中空状态**（数据管线一字未动）；**设置从内联面板改成 `ReaderSheetMode.SETTINGS` 的 sheet**（`settingsBar()`、`settingsOpen`、其 `onBackPress` 分支**全部删除**——阅读器现在只有一个覆盖层布尔量）；**设置只有「字号」一行**（字号是阅读器唯一真实的设置，刻意不发明控件）。× 只写 `this.sheetOpen = false`，与 `onBackPress`、目录跳转同一条关闭路径。

**护眼主题下已在真机验收**：

| 项 | 实测 |
|---|---|
| **顶部横条 / 背景不统一** | ✅ **消失**——`y=500/900/1400/2000` 四处采样**同为 `#F6EBD7`**（护眼调色板的 `card` 表面色） |
| **半高** | ✅ 见下方「半高的正确测法」——`y=1488 px = 440.9 vp`，占屏幕底部 **47.8%**（曾用 x≈0 的列扫描误报为 45.2%，那是圆角造成的偏低） |
| **四个 sheet 都能打开** | ✅ 两条入口（真实底栏 + 探针栏的格子）都能打开；日志 `reader sheet: toc/bookmark/note/settings` |
| **× 能关闭** | ✅ 关闭后采样回到页面底色 `#F2E7D3` |

**三个主题全部验收通过**（真机，12 种组合 = 4 sheet × 3 主题）：

| 主题 | container / header / body 三处采样 | 对照调色板 |
|---|---|---|
| 亮色 | 全部 `#FFFFFF` | = `card` ✅ |
| 深色 | 全部 `#1E1E1E` | = `card` ✅ |
| 护眼 | 全部 `#F6EBD7`（`card` 是 `#F5EBD7`，JPEG ±1） | = `card` ✅ |

**12 种组合里三处采样全部同值**，而且用**区域众数**（不只单像素）复核过。另外做了两项排除：**逐行众数扫描 sheet 前 220 行**（只有 sheet 色 + 抗锯齿边界 + ±1 噪声）、**在深色 sheet 内搜「宽的近白游程」**（杂散色带的特征，最长只有 43–56px = 标题字形墨迹）。**深色下没有一处白色。**

**关键教训：我给出去的旧底栏 x 坐标是错的。**

| | 目录 | 书签 | 笔记 | 设置 |
|---|---|---|---|---|
| 曾误用 | 194 | 440 | 690 | **940** |
| **实测** | **202** | **506** | **812** | **1119** |

**标签分界在 330 / 660 / 990**，所以 **`x=940` 落在「笔记」格子里——在 940 点「设置」会打开「笔记」，看起来和当年那个「点笔记弹出目录」的 bug 一模一样，但它只是坐标错。** 用户之前那次困惑很可能就是这个。

**半高的正确测法**：sheet 左上角**圆角约 34vp**，**沿 x≈0 的列扫描会在圆角下方才碰到 sheet 表面，导致读数偏低 13–21vp**。**真正的边界要用「全行众数色离开变暗页面」来定**：**`y=1488 px = 440.9 vp` → 占屏幕底部 47.8%**，与 `50% × (窗口 − 顶部安全区)` 的预测一致。**三个主题下都一样。**

**切换主题的真实路径**（本构建**没有「跟随系统」选项**）：阅读器返回 → 书架 → 底部「设置」页签 → **「主题」**（不是「外观/深色模式」）→ **浅色 / 深色 / 护眼** 三张卡。坐标见 `.diag/theme-findbar.ps1` 与那一轮的 `theme-sample.ps1`。

**两个已标记、待决的观察**：

1. **设置那张行卡在 sheet 上只靠 1vp 发丝线区分**——**它的填充色和背后的 sheet 逐像素相同**（因为两者都是 `card`）。三主题一致。**若希望它更明确，可改用 `muted` 底或加深发丝线。**
2. **深色下 Reader Kit 画的阅读区读数是 `#0A0A0A`，而应用自己的页面表面是 `#121212`**（调色板暗色背景）。**开关 sheet 都一样，所以不是 sheet 的产物。未调查。**

**两处由测量被迫做出的选择**（不是审美判断）：

- **sheet 表面用调色板的 `card`，不是读者的 `chromeSurface()`**：后者会让次要文字在亮色下只有 3.84:1、护眼下 3.18:1，**低于项目 4.5:1 的下限**；`card` 上同一角色是 4.88/6.38/4.61:1
- **sheet 的次要文字用 `sheetMuted()`，不是 `chromeMuted()`**：`chromeMuted()` 是「页面上的文字」用的，放 sheet 表面上护眼下只有 3.91:1，同样低于下限

**注意**：这一轮改了 6 条审计断言（都是被设计变更强制反转的，外加两个计数更新和一个半径白名单增加），子代理主动列出要求复核。**下次接手时值得逐条读一遍，确认那些反转是等价或更强的改写，而不是强度削弱。**

### r92–r93：表面层级、可拖拽高度、外部模糊、页面大标题（已完成）

**r92** 四件事：

1. **新增调色板角色 `cardSubtle`**（亮 `#F6F6F2` / 深 `#2C2C2C` / 护眼 `#FBF4E5`）。**读者 sheet 体仍是 `card`，设置那张行卡改成 `cardSubtle`**；行卡的图标块与步进按钮改用 `palette.border`（`sheetRowControl()`），因为旧的 `muted` 填充和被它压着的行卡几乎同色（亮 1.063 / 深 1.028）。**行↔体分离从 `1.000`（缺陷）变成 `1.083 / 1.194 / 1.080`。**
   - **亮色已在调色板天花板**：再走一步，行卡自己的副标题就会掉到 4.5 以下。**这个理由记在 `Theme.ets` 里。**
   - **诚实偏离**：读作「体更暗、行更亮」做不到——ReadAny 只有两个表面层级，所以行只能朝该主题中性色允许的方向离开 `card`（亮/护眼下更暗，深色下更亮）。
2. **三个页面大标题** `书架 / 书签笔记 / 设置`——**三个都本来就存在**（`Index.ets` 的 tab），**没有凭空造**。共享 `pageTitle()`：`TYPE_TITLE_LARGE`(30) + Bold + `palette.foreground`，**固定不滚动**（各 section 的第一子节点）。
3. **sheet 外的模糊**：**平台层没有任何选项**（`SheetOptions.blurStyle` 是 sheet 自己的背景、`maskColor` 只染蒙层、`BindOptions` 只有背景色 + 4 个回调）。**所以照 ClashBox 的做法手写 `.foregroundBlurStyle`，挂在「页面 Stack」而不是根 Column**（这样顶栏/底栏/sheet 保持清晰），`sheetBlurStyle()` 在 `sheetOpen` 时返 `Thin`。**真机实测：sheet 外是一整段平滑渐变（`#CBC5B7`→`#B0A99F`），没有锐利边缘 = 确实模糊了。** **诚实命名：毛玻璃/背景模糊，不是沉浸光感。**
4. **拖拽改高度**：`detents: ['50%', SheetSize.LARGE]`（**第一项既是开屏高度也是地板**）+ `onWillDismiss` 拒绝 `SLIDE_DOWN`（当时的理由：向下拖 = 关闭，不是缩小）。`height` 删除（有 `detents` 时被忽略）。**⚠️ 这个拒绝在 r94 被用户推翻并删除，见下。**
   - **「拖表头改高度、拖内容滚列表」不是谁写的代码，是平台行为**——**表头里没有可滚动的东西，所以拖拽落到 sheet 的识别器上；内容区的拖拽被列表先认领。** **ClashBox 源码确认它一行都没写**（只是不可滚动的标题 `Row` 放在 `List` 上面）。
   - **真机实测成立**：表头向上慢拖 → 顶边 `1492 → 200 以下`（扩张到满高）；内容区向上拖 → 顶边**不动**。
   - **代价（用户已接受）**：四个 sheet 仍以统一高度打开，**但可以被拖成不同高度，且 app 不记住**。

**r93**：**把设置类表面的 1vp `palette.border` 发丝线全部删掉**（`ListRow.ets`、`Index.ets` 的主题行/动画行/两张同步进度卡/探测面板、`SyncSettingsPage.ets` 两处、`ReaderView` 的行卡）。**保留「选中环」**（`borderWidth(选中 ? 2 : 0)`）**和控件边框**——**选中态不是内容边框。**

- **刻意没有给主设置页换 `cardSubtle`**：在 `background` 页面上 `card` 本身就已经是「离体一步」，而且**亮色下更强（1.143 vs 读者那张 1.083）**；换 `cardSubtle` 会把亮色压到 1.055（**比用户刚认可的 1.083 还弱**），**并且会让嵌在里面的 `muted` 同步进度条掉到 1.027/1.028（亮/深下不可见）**。
- **`ListRow` 的原型本来就无边框**（ClashBox `components/Common/Common.ets:813-819`，1.11:1 无边框）——**删线是让它更接近移植原型。**
- **⚠️ 一个勉强及格、已标记的情况**：**护眼下 `card` 卡片 vs `background` 页面只有 `1.047:1`**（比项目给行卡定的 1.05 低 0.003）。**亮/深从容（1.143 / 1.124），护眼是应用里最弱的无边框表面。** 退路：把那几处填充换成 `cardSubtle`（1.055/1.341/1.131），**代价是亮色变软 + 要连带改同步进度条。**
- **待用户确认的一项**：**「把内容的边框去掉」是否也包括「书签笔记」页的标注卡片**（`AnnotationsPage.ets:239-240`，护眼填充同样约 1.047）。**子代理没有擅自动，等确认。**
- 它发现并修正了注释里的陈旧数字（曾有 `#FAFAF6` 这个已放弃的候选色、以及一个无法复现的 `1.199:1`）——**把五个填充数字全部换成重算值，并在注释里记录了这次替换，而不是悄悄覆盖。**

**审计基线推进**：`3289`（探针前）→ `3328`（r92 前）→ `3368`（r92）→ `3377`（r93，失败 2 条，都是可移除诊断探针的 `MaterialLevel` 触发的）→ **`3408`（r94，失败仍是同 2 条）**。

### r94：边框回归 + sheet 改成「背景灰 / 内容白」（已完成构建，未装机验收）

**这一轮是用户看着已安装的 r93 构建做出的裁决，推翻 r93 的两条决定。**

1. **发丝线全部回归。** r93 按「填充算得过去」删掉了设置类表面的 1vp `palette.border`（`ListRow.ets`、`Index.ets` 的主题行/动画行/两张同步进度卡/探测面板、`SyncSettingsPage.ets` 两处、`ReaderView` 的行卡）。用户看真机后说 **「还是保留边框吧，护眼模式下确实看不清」**。所以**算术没错（护眼 1.047:1 确实是 1.047:1），是算术不够**——**填充比值不是「表面是否可见」的度量**。**这是本项目第三次被「目视 vs 测量」教训，但方向和前两次相反：这次是测量值合格、目视不合格。** 恢复处一律 **1vp `palette.border`**；**2vp `primary` 选中环保留**（那是状态），两个 picker 的 `borderWidth` 表达式回到 **`2 : 1`**。
2. **读者四个 sheet 的配色翻转为「背景灰 + 内容白」**，与主设置页一致：`sheetCard()`（体/表头/`bindSheet` 容器）= `palette.background`，`sheetRow()` = `palette.card`。三主题全部。**这是 r92 做不到的方向**——r92 保留了 `card` 体，而亮色下 `card` 已是纯白，行无处可去；**r94 改的是「体」**，于是参考实现（ClashBox：灰 sheet + 白行）的表达成为可能。
   - **`cardSubtle` 角色已删除**（接口字段 + 三个调色板值 + `verify-themes` 里那 6 条断言）。它唯一读者是 `sheetRow()`，体变灰后它「写了没人读」。
   - **⚠️ 连带发现：`mutedForeground` 在 `background` 体上低于下限**（亮 **4.27:1**、护眼 **4.40:1**）。**体的次要文字改用 `chromeMuted()`**（页面派生色，体现在就是页面色）：7.29 / 8.74 / **4.67:1**。**行内**次要文字仍用 `mutedForeground`（行是 `card`，4.88/6.38/4.61:1）。所以 `sheetMuted()` 被拆成「体用 `chromeMuted()`、行用新的 `sheetRowMuted()`」。**护眼 4.67:1 是三者中最紧的，而它本来就是页面指示器一直在用的旧数，不是新造的余量。**
   - 行内控件填充仍是 `palette.border`（在 `card` 上 1.271/1.319/1.447:1）。**`muted` 现在其实也读得出来（1.112/1.161/1.177:1），但 `border` 更强、且与 × 圆片同一角色。** × 圆片在灰体上是 1.113/1.483/1.383:1（`muted` 在灰体上只有 1.027:1，所以不能用）。
   - **⚠️ 未验证的风险：sheet 体 = 页面色，所以 sheet 与页面的分界只剩平台阴影 + 32vp 圆角 + sheet 外那层模糊。** r92 真机测过护眼下外部模糊是 `CBC5B7`→`B0A99F` 的平滑渐变，与 sheet 面明显不同，所以应该看得见——**但这是 r94 的构建没有实测过的推论。**
3. **`onWillDismiss` 不再拒绝 `SLIDE_DOWN`。** 用户：**「现在以打开的时候的默认高度为最小高度，当在最小高度向下滑的时候就视为关闭sheet」**。平台自己的规则就是这样：半模态面板 · 使用嵌套滚动交互 —— **「下滑时，优先向下收缩面板挡位，如无挡位可收缩，则关闭面板」**；`changelogs-ux-b031` 也写 **「在最低档下滑可以关闭半模态」**。所以手势是：`LARGE` 向下拖 → 收到 `50%`；再从 `50%`（也就是开屏高度）向下拖 → **关闭**。r92 的拒绝把这个手势砍成了半步。**`onWillSpringBackWhenDismiss: () => {}` 保留**——SDK 参考写得很清楚：**「若不注册该回调函数，但注册 shouldDismiss 或 onWillDismiss 时，则默认在下拉关闭时，会触发回弹效果，回弹后再根据…决定半模态是否关闭」**，所以它不是拒绝逻辑的残留，而是「下滑不先弹一下」的那件事（官方示例 4 也是这个写法）。
   - **「这三个 sheet」只能是四个一起。** 用户说「这三个 sheet」，但四个 sheet 共用**唯一那个 `bindSheet` 宿主**，所以关闭行为是全局的，**按 sheet 分开需要第二个宿主——被硬约束禁止**（§6.4）。
   - **本轮的构建没有装机**，所以这条手势行为**只在文档层面确认过**；r92 的真机测量（表头上拖 → 顶边 1492 → 200 以下，且不触发关闭）与之一致，那是「切换挡位不走 `onWillDismiss`」的独立证据。

---

### r95：下拉关闭后短时间内再开 sheet 会直接关闭（已修，待真机用日志确认机制）

**用户的原始报告**：**「在用下拉的方式关闭sheet后（点击圆形X不会触发这个问题），短时间内再点击sheet，会直接关闭。」** 关键线索是**× 不触发、只有拖拽触发**。

**机制（文档 + 代码，真机日志待补）**：

1. **框架的离场动效不可打断。** SDK 参考原文：**「半模态页面的离场动效不支持打断，动效执行期间无法响应其他手势动作……视觉上半模态页面已经消失，但此时动效可能还未结束，若想再次点击拉起半模态页面则不会响应。需要等动效完全结束后，才可以再次拉起」**（`ts-universal-attributes-sheet-transition`）。`onDisappear` 就是「动效完全结束」那一刻（生命周期表把它标为「动画结束后」，`common.d.ts:11307`）。
2. **两条关闭路径抵达那个窗口的方式不同，这就是不对称的来源。** × 是应用写的 `sheetOpen = false`（`ReaderView.ets` 的 `sheetHeader`），框架看到绑定变量变化而启动离场，绑定回写与状态从第一帧就一致。**拖拽是框架自己发起的**：参考文档明说 **「在非双向绑定情况下，以拖拽方式关闭半模态页面不会改变isShow参数的值」**，`$$` 才是同步它的东西——所以 `onWillDismiss` 是框架自己的关闭流程里的一个决策点，**它之后的回写会落在应用下一步动作之后**；写在那个区间里的 `sheetOpen = true` 会被丢掉（动效不可打断），随后回写把 `sheetOpen` 留成 `false` = 「再点直接关闭」。
3. **r95 的修法**：`ReaderView` 新增 `private dismissing: boolean`。**每个关闭点**（`onBackPress`、× 的 `onClick`、`onWillDismiss`）先置 `true`，**`onDisappear` 里清掉并重放被挂起的开启请求**（`else`/`if` 见 `openReaderSheet`）。`onWillDismiss` 里 `sheetOpen = false; action.dismiss();` 那对**一字未动**（`verify-reader-chrome` 断言它，且它守的是「最低档下拉能关」）。**拖拽手势本身没有被碰过。**
4. **为什么这不是掩盖症状**：被消除的是「应用在框架的关闭流程还没结束时去写同一个状态变量」这件事本身——即两条路径唯一的差别。重放发生在框架自己宣告「结束」的回调里，不是在猜时间。

**诊断探针（可移除，独立于材质探针）**：`.diag/strip-sheet-probe.mjs`（**5 个 `DIAG-SHEET` 块 + 13 行 `// DIAG-SHEET` 标记**，不是材质探针的 4 个 hunk）。它删完会**恢复**：`onWillSpringBackWhenDismiss` 的空函数体、`sheetOpen` 上的 `@Watch`、以及三个只用于观测的 `onWillAppear`/`onAppear`/`onWillDisappear`。**`onDisappear` 是修法本体，必须留着。** 每条日志以 **`SHEETPROBE`** 开头、带单调 `seq` 与毫秒 `t`，另有 `@Watch` 行记录**任何**对 `sheetOpen` 的写入（含 `$$` 回写）。另有 `.diag/make-probe-only-variant.mjs` 可把修法关掉（`if (false)`）以便原样复现 bug。

**证据状态：`uinput` 复现不了。** 已试：单次拖拽（`-m 660 1700 660 2700`，速度 1500/1200）、6 档延迟扫描（0/50/120/200/350/600ms，延迟在**设备上**精确执行）、成对 × 对照、连续两次拖拽、10 组配对试验——**每次重开都成功**。原因是 `hdc shell` 单次进程往返约 1.4s，注入的手势永远晚于那个几百毫秒的窗口；**这不能作为「bug 不存在」的证据**（§3.4 已记录过两次同类情况）。**待用户手动复现并把 `SHEETPROBE` 轨迹交回。**

**审计基线**：探针在场时 **30 工具 / 3408 项 / 3406 通过 / 2 失败**，失败的仍是材质探针那两条 `MaterialLevel`（`verify-reader-chrome` 的 "no material level…"、`verify-themes` 的 "ReaderView.ets uses no system material"）。**这一轮改了 1 条断言**：`verify-reader-chrome` 的 `onWillSpringBackWhenDismiss` 那条，放宽到「允许恰好一次 `onSheetSpringBackProbe()` 调用」，同时**新增** `!/springBack\s*\(/ && !/SpringBackAction/`——**更强，不是更弱**。

---

### r96：开屏改为立即写 + `@Watch` 按 cycle 修复（已修，用户已确认跟手）

**r95 的手工轨迹推翻了自己的修法**：离场是**固定 ~590 ms**（11/11，589–600 ms，× 和拖拽**一样**），而框架的 `$$` 回写落在 **`onDisappear` 开始后 5–10 ms**。所以「在 `onDisappear` 里重放开启」既留不住面板、又让每次快速重开都等一整个离场动画——用户的原话是 **「关了再开有点不跟手，会让人感觉有延迟」**。

**r96 的做法**：`onSheetWillDismiss` 里**不再写 `sheetOpen`**（那是唯一一处「在框架的关闭决策中间写同一个绑定变量」），开启**立即写**，被框架回写覆盖则由 `sheetOpen` 上的 `@Watch` → `onSheetOpenSettled()` **按 cycle 修复**，上界 `SHEET_MAX_RAISE_ATTEMPTS = 3`。

**cycle 字段就是这一整套机制的名字**（`sheetCycle` / `sheetShownCycle` / `sheetCloseCycle` / `sheetIntentCycle` / `sheetRaiseAttempts`），`sheetOpen = false` 仍然**全文件只出现一次**（在 `finishSheetClose`）。

**轨迹里最重要的一条事实**：**框架会在新面板自己的 `onWillAppear` 之后约 590 ms 再补一次 `reason=3`（`DismissReason.SLIDE_DOWN`）的 `onWillDismiss`**——`.diag/r95-hand-trace.txt` 的 `seq 348`。也就是说「上一个关闭」会在「这一个开启」之后仍然活着。**这一条是 r98 的直接原因。**

### r97：毛玻璃独立成 `sheetBlur` 渲染门（已修；r98 补上它的修复路径）

**用户报告**：拖拽关闭后毛玻璃会留在屏幕上（× 不会）。**根因**：模糊原本直接读 `sheetOpen`，而这个变量在拖拽路径上是**框架在离场末尾回写**的（`onDisappear` +592 ms，回写 5–10 ms 后），所以「由 `sheetOpen` 导出的模糊」**就是**离场尾巴；× 那条是应用自己写的，所以立刻清。

**r97 的做法**：新增 `@State private sheetBlur: boolean`，在**开启处**抬、在**两个关闭决策点**（`finishSheetClose`、`onSheetWillDismiss`）+ `onDisappear` + `onSheetOpenSettled` 清。命名规则照旧：**这是毛玻璃/背景模糊，代码和注释里都不许叫沉浸光感。**

**r97 留下的缺口（r98 修的就是它）**：`sheetOpen` 有**修复路径**（`onSheetOpenSettled` 里被回写覆盖后重新抬起），`sheetBlur` **没有**——所以「晚到的关闭」清掉模糊之后，面板被修回来、模糊没有。

### r98：模糊门也服从 cycle 纪律（已修，待真机用 r98 探针确认）

**用户报告**（装完 r97 几秒后）：**「如果正常打开，遮罩是正常的。如果关掉立马打开，遮罩会出现异常。现在点击sheet外面也会关掉sheet，这个逻辑没问题。但是这样关掉的话，会和下拉关闭一样。」**

**根因（代码 + r95 轨迹，不是猜的）**：`sheetOpen` 和 `sheetBlur` 的「同一帧成对写」只覆盖了**开启**和**两个关闭决策**，漏了**修复**。`onSheetOpenSettled` 重新抬起 `sheetOpen` 时**没有同时抬 `sheetBlur`**，于是「上一个关闭仍然活着」的那个 cycle 结束时：面板在（修复抬的）、模糊不在（晚到的关闭清的）= **有面板、没毛玻璃**。轨迹给出确定性：框架在面板 `onWillAppear` 后约 590 ms 补一次 `reason=3` 的 `onWillDismiss`（`seq 348`），它后面的 `$$` 回写正是修复响应的事件。

**r98 的两处改动（都在 `ReaderView.ets`）**：

1. **`onSheetOpenSettled` 的修复把两个变量一起抬**：`this.sheetBlur = true;` 紧挨 `this.sheetOpen = true;`，同一个 attempt、同一个 `SHEET_MAX_RAISE_ATTEMPTS` 上界——**所以不可能震荡**：它不是新的重试机制，只是同一次重试多写一个变量。
2. **`onSheetWillDismiss` 的清**由新的 `sheetDismissalIsStale()` 看着：**只用现成的 cycle 字段**（`sheetIntentCycle !== sheetCycle && sheetShownCycle !== sheetCycle`，或 `sheetCloseCycle === sheetCycle`），**从不读 `sheetBlur` 本身**（否则门就变成了「面板在不在」的第二个答案）。正常关闭三个条件都不成立 → 照旧在决策点清（r97 的修法保住）。
3. **`onDisappear` 的清保持无条件**，这是刻意的另一半：晚到的关闭对门**不被服从**，所以「保住门的那个 cycle」可能一次清都没有，这一行是「有毛玻璃没面板」不可能发生的保证。

**`sheetOpen = false` 仍然全文件一次（`finishSheetClose`）**；`sheetBlur` 变成 **6 写（2 抬 4 清）/ 1 读**（探针的 `@Watch` handler 是第 2 个读，可移除）。

**外部点击关闭的结论**：`DismissReason` 声明里 `TOUCH_OUTSIDE = 1`（点遮罩）、`SLIDE_DOWN = 3`（下滑），而官方 `shouldDismiss` 参考写明「下拉关闭、侧拉关闭、**点击遮罩层关闭**、点击关闭按钮」都走交互式关闭回调——**所以外部点击和拖拽是同一条 `onWillDismiss` 路径，用户的观察是对的**，r98 的守卫对 `reason=1` 同样成立（它检查的是 cycle，不是 reason）。**r95 那份轨迹里 11 次关闭全是 `reason=3`**，因为那次的动作全是拖拽。

**r98 的探针**：`SHEETPROBE` 新增 `tag=WATCH blur-changed`，**门的每一次写入都有一行**（`now=true|false`），和 `sheetOpen` 的 `WATCH sheetOpen-changed` 对称。`.diag/strip-sheet-probe.mjs` 现在切 **9 个块**，并且要**把 `@Watch('onSheetBlurProbe')` 那行删掉、把声明还原**（这个 `@Watch` 属于探针，不属于修法——和 `sheetOpen` 上那个相反）。`.diag/r98-capture.ps1` 写明「正确/错误各自长什么样」。**`ReaderView.ets` 的 `sheetCycle` 文档块里那些轨迹 seq 号已按磁盘上的文件核对并改正**（正确配对是 182→187、201→206、262→267、281→286、356→361；r97 写的 265→267 / 320→322 / 358→361 在磁盘上指向别的行）。

**审计基线**：**30 工具 / 3416 项 / 3414 通过 / 2 失败**（34 行 `Select-String 'passed'`），失败的仍是那两条 `MaterialLevel` 探针自身。**这一轮改了 `verify-reader-chrome` 的 5 条模糊断言**（3 条改写、2 条新增）：抬的计数 1→2、读的计数改为**由探针在场与否推导**（带探针 2 读、stripped 变体 1 读，**两种变体都跑过**）、新增「修复必须和 `sheetOpen` 同块一起抬」「`onWillDismiss` 的清必须在 `sheetDismissalIsStale` 里且该谓词不得读门」「`onDisappear` 的清必须**不带**守卫」。**`verify-book-menu` 的 stamp pin 改成 r98。**`.diag/r98-mutate-blur-gate.mjs`：**7/7 全部被抓**。

**新增可移除产物**：`.diag/ReaderView.r98-stripped.ets`（探针全删后的变体，**也要通过审计**——`.diag/r98-strip-check.mjs` 同时跑两种变体）。

---


## 10. 用户明确搁置 / 待办

- **阅读统计**（用户：「暂时不做，放到后面」）
- FX：**沉浸光感档位选择器** —— **已确认不必要**（系统提供三档并自动映射）
- 按需单本下载（`downloadBookFile` 带新布局 → 旧 `/readany/data/file/{id}.ext` → 标题扫描的兜底链）
- 工程卫生：把审计基线写进文档、更新 `docs/harmony-delivery.md`

---

## 11. 子代理派活清单（照抄用）

**必须包含**：

1. **硬约束**（§2 全部，尤其「绝不改 ReadAny」「不动 `queueBusy`」「备份放仓库根」）
2. **文档来源优先级**：**优先 MCP**（工具名 + 「健康检查会说谎」），网页是回退
3. **验证方式**：构建（增量 + 一次 clean）、审计逐工具相加并报出数字与失败的准确集合、**以及「预期失败是哪几条」**
4. **`BUILD_STAMP` 要改**
5. **包无签名、agent 装不了**——构建、报路径 + size + SHA-256，**让用户装**，**不得声称未取得的真机结果**
6. **`Select-String 'passed'` 34 行 / 30 工具、四个非计数工具**的提醒，并**把正确的汇总正则给它**（`(\d+)/(\d+)\s+\S*\s*checks passed,\s*(\d+) failed`）。**简写成 `(\d+)/(\d+) checks passed` 会漏掉 8 个工具**（前缀词 `book-menu`/`coverage`/`motion`/`structural`/`reader-chrome`/…），见 §12.5
7. **`pwsh` 与 `uinput` 的坑**（§3.4、§3.5）
8. **如实报告「无法确定的部分」**
9. **要它说明「每个结论的来源」**（MCP / SDK 声明 / 实现源码 / 真机）
10. **如果要改审计断言，必须列出改了哪条、为什么、以及是否等价或更强**

**要求它**：先调研给方案 → 用户确认 → 才动代码。**不要擅自开始实现。**

---

## 12. 代码托管、开源协议与推送通道（r99，2026-10）

**这一节的每一条都是「不该再被重新推导」的事实。**

### 12.1 代码托管

| 项 | 值 |
|---|---|
| 已配置的 `origin` | `https://github.com/hkb65536/ReadAny-ohos.git`（HTTPS；**2026-10-26 实测**） |`r`n| 可推送的远端 | `git@github.com:hkb65536/ReadAny-ohos.git`（SSH，见 §12.3） |
| 分支 | `main`（新仓库的默认分支，也是唯一分支） |
| 仓库本体 | **仓库根自己就是 git 仓库**（`D:\Code\ReadAny-ohos\.git`，就地 `git init`）；工作区根与工程根是**同一个目录** |
| 首个提交 | `7bd8aee` `feat(harmony): 导入 InkBoat 鸿蒙移植工程` —— **根提交（无父）**，121 文件 |
| 第二个提交 | `0e52334` `docs: 补齐 GPL-3.0 协议文本与来源声明` —— +3 文件 → **124** |
| 第三个提交 | `1561010` `feat(reader): 浮动两栏 + 三分区点击覆盖层（r100）` —— 4 文件（+695/−495）。**只在本机，尚未推送** |
| 协议 | `LICENSE` + `NOTICE` + `README.md`（见 §12.6） |

**⚠️ 提交纪律（用户 2026-10 明确要求）：本地提交是硬要求，推送不是。**

- **每次修改代码后立刻在本地提交，不要攒着**：

  ```powershell
  git -C D:\Code\ReadAny-ohos add -A
  git -C D:\Code\ReadAny-ohos commit -m "<type>(<scope>): <说明>"
  ```

- **不要每次都推远端。** `git push` **只在用户明确要求时才执行**——他会自己说要推。**默认状态就是「本地领先 `origin/main` 若干提交」，这是期望状态，不是未完成的工作**，不要自作主张去对齐。
- **一轮结束时 `git -C D:\Code\ReadAny-ohos status --porcelain` 必须为空**（不留未提交的代码改动）。
- 这条纪律的由来：**r100 那轮（浮动两栏 + 三分区覆盖层）改了代码却一直没提交**，直到建立这条规则时才补上（§9 r100）。**改了不提交 = 没有版本历史兜底。**
- 提交身份不用管（仓库级已是 `hkb65536 <github-email>`，§12.2）；真要推时目标是 `origin/main`、走 SSH（§12.3）。

- **历史沿革（那两条已不存在，别去找）**：最初推到的是 `AyaseEil/ReadAny` 的一个 `ohos` 分支（空提交 `faeed4b` → 导入提交 `f35991e`）。**那个仓库和那两个提交都已经不存在**；它们在本机是**不可达对象**（`git fsck --unreachable` 能看到），**刻意没有 gc 掉**（旧仓库已删，这是它们唯一的存在处）。
- **tree 哈希是 `e74b7598`**：导入提交与后来「重新推」的那个提交**共用同一个 tree** —— **所以换仓库没有改变任何一个字节**，上一轮的审计结论继续有效（tree 相同 = 输入字节相同，不必重跑）。

### 12.2 提交身份（**仓库级，不是全局**）

- 本仓库的**仓库级**配置：`user.name = hkb65536`、`user.email = <github-email>`。
- **全局配置仍是 `Huangkb` / `huangkb@yunqingtech.com`，绝不要改。** 用户明确要求「只改这个仓库」——`ReadAny`、`ClashBox` 以及以后新建的仓库都沿用全局身份。
- `<github-email>` **已绑定该 GitHub 账号**：GitHub 的 `/commits/main` 返回 `author.login = hkb65536`，头像与主页链接都对。

### 12.3 账号更名与推送通道

- **`AyaseEil` 已更名为 `hkb65536`，是同一个人**（user id 都是 `<github-user-id>`）。SSH key 没换：`ssh -T git@github.com` 现在回 `Hi hkb65536!`（以前回 `Hi AyaseEil!`）。**不要把这两个名字当成两个账号，也不要去申请新凭据。**
- **推送必须走 SSH。** 本机 pwsh 里的 HTTPS/**schannel 是坏的**——连 `https://www.baidu.com` 都报 `SEC_E_NO_CREDENTIALS (0x8009030e)`，`github.com:443` 直连被 reset，`gh-proxy.org` 只能拉不能推。但 **Node 的 `fetch`（自带 OpenSSL）是好的**——这轮所有 GitHub API 复核都走它（`node -e "fetch(...)"`），`api.github.com`、`www.gnu.org` 都能取。**要查 GitHub 就用 Node，不要用 `Invoke-RestMethod`。**
- **拉取（fetch/pull）实测可用的通道是本机 SOCKS 代理**（2026-10-26）：`git -c http.proxy=socks5h://127.0.0.1:10808 fetch origin` —— v2rayN 的 xray 在 `127.0.0.1:10808` 提供 SOCKS5。**直连 HTTPS 会 `Recv failure: Connection was reset`**。这是**一次性参数，不要写进全局配置**：代理一关，所有 git 操作都会失败。
- 收紧沙箱时 `git push` 曾因 git 用 `sh` 拉起 ssh 而报 `sh.exe: *** fatal error - couldn't create signal pipe, Win32 error 5`（当时靠 `GIT_SSH=C:\WINDOWS\System32\OpenSSH\ssh.exe` 绕开）。**当前政策（danger-full-access）下普通 `git push` 直接可用**，不需要任何绕行参数。
- 同理，`git credential fill` 那条路是死的（凭据助手是 shell 包装脚本，沙箱里起不来）。

### 12.4 `.git` 不影响审计（已用诱饵实验证明）

- 7 个会遍历目录的工具**都到不了 `.git`**：起点是 `<模块>/src`（`verify-objective-coverage.mjs:60-63`、`verify-book-paths.mjs:349-350`）**且只收 `.ets`**；两个全局 walker 更是**显式跳过 `.git`**（`verify-tombstone-bound.mjs:90`、`verify-sync-v1.mjs:153-154`）。
- **诱饵实验**：往 `.git/` 里放一个含 `#FF00FF`、`cleanupRemoteOrphans`、`forceApply`、`PROPFIND`、`If-Match` 的 `.ets` 诱饵，7 个 walker 的计数**一个都没变**。**结论：`.git` 里的压缩对象永远进不了证据集。**
- **这条只对 `.git` 成立。硬约束 #7 依旧**：备份仍旧绝不放模块目录里。**仓库根就是 git 仓库，提交本身就是备份机制**——随手丢 `.bak` 反而会被审计当成活代码。
- 顺带记录：`.backup-local-dir-parent/`（4 个文件）**已消失**（r99 会话中途发现它不在了，不是 agent 删的）。

### 12.5 审计汇总的正确写法（**这里以前算错过**）

工具的汇总行格式是 **`N/M <前缀词> checks passed, K failed.`**，前缀词有 `book-menu` / `coverage` / `motion` / `structural` / `reader-chrome` / `sync-progress` / `routing` / `sync-v1` 等。正确的正则：

```
(\d+)/(\d+)\s+\S*\s*checks passed,\s*(\d+) failed
```

**用 `(\d+)/(\d+) checks passed` 会静默漏掉 8 个工具**（r99 实测：漏掉后合计 `1990`，正确合计 `3410`）。

- **r99 实测：30 工具 / 3412 项 / 3410 通过 / 2 失败。** 失败的仍是材质探针那两条，**但两条的文本不同，别记混**：`verify-reader-chrome` 的是 `no material level / immersive treatment in the reader`，`verify-themes` 的是 `ReaderView.ets uses no system material`。
- **本文档 §9 各轮记的 `3408` / `3416` 是「34 行口径」**——把 4 条非计数行各算 1。**只数 30 条汇总行就是 `3412`。** r99 的 3412 与「3416 − 4」精确吻合，但**没有逐工具核对过 r98 的原始数字**，所以「历史基线是不是同一口径」**这一点未证死**；引用旧数字时请说明口径。

### 12.6 开源协议：GPL-3.0-or-later（衍生作品）

- 上游 [ReadAny](https://github.com/codedogQBY/ReadAny) 是 **GPL-3.0-or-later**（`LICENSE` 抬头的授权句 + `package.json` 的 `"license": "GPL-3.0-or-later"` + README，三处一致），© 2024 ReadAny Team。
- **本仓库是它的衍生作品**，证据是项目自己的记录：**逐字复制的文案**（`书籍文件将从书架移除。` 同时在 `entry/src/main/ets/pages/ShelfPage.ets:675` 和 `ReadAny/packages/core/src/i18n/locales/zh/library.json:73`）+ **同步协议逐字段复用** + 界面行为以 ReadAny 为准。**因此必须整体按 GPL-3.0 开源并保留声明——这不是可选项。**
- r99 已补齐三份文件（提交 `0e52334`，在 `main` 上）：
  - **`LICENSE`** = **FSF 官方 GPLv3 正文，逐字节未改动**，SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`。**两个独立来源同哈希**（`gnu.org/licenses/gpl-3.0.txt` 与 GitHub 的 `licenses/gpl-3.0` 正文），所以这个哈希可以直接当校验值用。
  - **`NOTICE`** = 按 GPLv3 §5(a)(b) 写的「本作品已被修改（2026，hkb65536）」声明 + 「整体按 GPL-3.0-or-later 发布」声明。
  - **`README.md`** = 来源与归属、逐字段复用的远端路径表、模块表、构建方式（`ohpm install --all` + `build.bat assembleHap …`）、协议说明。
- **GitHub 的协议识别从 `NOASSERTION` 变成了 `GPL-3.0`**（对齐前是 "Other"）。它标 `GPL-3.0` 而非 `GPL-3.0-or-later`，因为官方正文里不含 "or later" 字样——**"or later" 属于授权声明（README/NOTICE），不属于协议正文**（FSF 附录也这么要求）。**绝不要为了迁就徽章去改协议正文。**
- **⚠️ 上游那份 `LICENSE` 的正文被改过。** 与两个彼此逐字节相同的官方来源比对，`§7` 有两处：
  | 位置 | 上游那份 | 官方 GPLv3 |
  |---|---|---|
  | §7 第三段 | `you have or can give copyright permission` | `you have or can give **appropriate** copyright permission` |
  | §7 第一段 | `(if **copyright holder of the material**)` | `(if **authorized by the copyright holders of that material**)` |
  **所以绝不能从 `ReadAny/LICENSE` 抄协议正文**，必须取 FSF 官方文本。这也是上游 GitHub 徽章显示 "Other" 的根因之一（另一个是它加在正文前的自定义抬头）。**已报告用户；是否上报上游由他决定，不要擅自去动别人的仓库。**

### 12.7 `build.bat --install` 的 `%*`/`shift` 问题（未修，不要擅自改）

`build.bat` 的 `--install` 分支先 `call ohpm.bat install --all`，再 `shift`，然后 `call hvigorw.bat %*`。**cmd 的 `%*` 不受 `shift` 影响**（已用最小 `.bat` 实测：`shift` 前后 `%*` 一模一样），所以 `--install` 会被**透传**给 hvigorw：

```
build.bat --install assembleHap ...   →   hvigorw --install assembleHap ... --no-daemon
```

**hvigorw 是否恰好也认 `--install` 没有验证过**，所以稳妥做法是分成两条命令（README 里就是这么写的）：

```powershell
& "$env:DEVECO_HOME\tools\ohpm\bin\ohpm.bat" install --all
.\build.bat assembleHap --mode module -p product=default
```

**用户尚未决定是否修 `build.bat`。**

### 12.8 上游参照实现的本地检出（`D:\Code\ReadAny`，固定 `v1.3.6`）

| 项 | 值 |
|---|---|
| 路径 | `D:\Code\ReadAny` |
| 远端 | `https://github.com/codedogQBY/ReadAny.git`（clone 时经本机 SOCKS 代理，直连会被 reset） |
| HEAD | `8d3f74a1` `fix(ci): give Android R8 more heap`（2026-08-16）＝ **tag `v1.3.6`** |
| 分支 | 只有 `pinned-v1.3.6`（`main` 与 **98 个** `refs/remotes/origin/*` **已删除**） |
| tag | 33 个，**全部在 v1.3.6 的历史之内**（没有一个指向其后） |
| 对象 | 可达提交 1104，unreachable **0**；`.git` 54.4 → **47.6 MB** |
| 工作区 | 32.1 MB / 1395 文件，`git diff v1.3.6` 为空 |

**为什么删掉 main 与 98 个远程分支引用**：用户明确要求「定到 v1.3.6，之后的代码不要」。只删 `main` 不够——那些 `origin/*` 分支也指向 v1.3.6 之后的工作，留着它们会让后来的 `git log --all` 和 `git grep` 看见不属于 v1.3.6 的代码，等于「之后的代码」还在。

**防止重新拉回**：`remote.origin.fetch` 已收窄为 `+refs/tags/v1.3.6:refs/tags/v1.3.6`，所以误跑 `git fetch` 不会把 main 和那些分支带回来。

**恢复全部历史**（需要时，经代理）：

```powershell
git -C D:\Code\ReadAny config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git -C D:\Code\ReadAny -c http.proxy=socks5h://127.0.0.1:10808 fetch origin
```

---

## 13. 一句话总结这个项目的工作方式

> **查证而不是猜测 · 测量而不是目视 · 如实说出做不到的部分 · 绝不削弱验证 · 先给方案再动代码。**
