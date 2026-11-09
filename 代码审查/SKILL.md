---
name: 代码审查
description: 审查代码改动或整份文件：四阶段流程 + 严重度分级，产出带 file:line 与可追溯依据的 finding。含 shell/Magisk、KSU WebUI、smali 三档与 20+ 语言档。
---

# 代码审查

目标：把「看起来不对」变成**能被反驳的具体断言**——每条 finding 都有位置、有依据、有改法。

## 0. 四条可移植性原则

1. **零网络依赖**：所有规则档随技能目录分发，断网可用。
2. **零包硬依赖**：不假设装了某个包或工具。工具（`shellcheck`、`python3`、`git`）探测到就增强，探测不到就不提。
3. **零设备假设**：不写机型、核心编号、本机独有的工具链路径。凡涉及系统行为，先实测（`command -v` / `ls` / `--help`）再判定。
4. **路径自定位**：`<SKILL_DIR>` = 本 SKILL.md 所在目录，Operit 默认 `/sdcard/Download/Operit/skills/代码审查/`。换设备只需替换这个前缀。

## 1. 开工前十秒

先问清三件事，缺一项就会把审查做成读后感：

| 要确认 | 为什么 | 不知道时怎么办 |
|---|---|---|
| 审查范围 | 「刚刚的改动」和「这个文件」是两种工作量；diff 超过约 400 行，结论会失真 | 先要 diff；拿不到就按文件审，并在报告里写明范围 |
| 代码要做什么 | 没有意图就没有「bug」，只有风格偏好 | 让用户一句话说清预期行为 |
| 运行环境 | shell 要区分 mksh/bash/busybox；前端要区分浏览器/WebView | 读 shebang、读构建配置，别猜 |

## 2. 四阶段

**阶段 1 · 上下文**：范围、意图、语言与运行时、有无测试。
**阶段 2 · 整体**：方案是否解决对的问题；模块边界；性能量级；错误处理策略；可测性。大改动读 `upstream/architecture-review-guide.md`。
**阶段 3 · 逐行**：逻辑与边界、安全、可维护、**复用审计**（这段是不是重复实现了已有的东西）。
**阶段 4 · 结论**：先结论后依据；给严重度分布；明确「能不能合」。

阶段 2 和 3 允许跳读，但不许跳过：只做逐行会漏掉「实现得很干净的错方案」。

## 3. 严重度与 finding 格式

| 级别 | 含义 | 处理 |
|---|---|---|
| 🔴 blocking | 会出错、会丢数据、会破坏可还原性、安全漏洞 | 必须改 |
| 🟡 important | 会误导后来人、埋雷、或不符约定 | 应该改 |
| 🟢 nit | 偏好问题 | 可以不改 |
| 💡 / 📚 / 🎉 | 建议 / 讲解 / 表扬 | 不阻断，只标注 |

每条 finding 固定七列，缺列就是意见不是结论：

```
| # | 严重度 | 位置 | 问题 | 依据 | 建议 | 存疑 |
```

- **位置**：`file:line`；跨文件就写主责文件 + 关联点。
- **依据**：必须是可指认的东西——`android/shell-magisk.md#备份只写一次`、`upstream/c.md#Always carry size with buffers`、某条命令的实测输出。写不出依据就降级到「存疑」。
- **建议**：给出方向即可，不要替用户重写整个文件（见 §7）。
- **存疑**：`未实测` / `依赖具体内核` / `需在目标机确认`。**这一列是本技能的信誉来源**：把推测混进结论，一次就够让整份报告作废。

## 4. 路由表

按**文件类型**选档，不按项目语言选。多类型混合就分节审。

| 看到什么 | 读哪份 |
|---|---|
| `*.sh`、模块目录、`post-fs-data.sh`、`service.sh` | `android/shell-magisk.md`（**优先于任何上游档**） |
| KernelSU/APatch WebUI、单文件 HTML、`ksu.exec` | `android/ksu-webui.md` |
| `smali/**`、`res/**`、`AndroidManifest.xml` | `android/smali-apk.md` |
| 其他语言 | `upstream/<lang>.md`：`c` `cpp` `csharp` `go` `java` `java8` `kotlin` `python` `php` `ruby` `rust` `swift` `dart` `typescript` `zig` `qt`；前端 `react` `vue` `angular` `svelte` `css-less-sass`；后端 `django` `fastapi` `nestjs` |
| 跨领域 | `upstream/cross-cutting/`：`sql-injection-prevention` `xss-prevention` `n-plus-one-queries` `error-handling-principles` `async-concurrency-patterns` |
| 通用质量 | `upstream/code-quality-universal.md`、`upstream/common-bugs-checklist.md`、`upstream/security-review-guide.md`、`upstream/performance-review-guide.md` |
| 反馈怎么说 | `upstream/code-review-best-practices.md` |

上游档是英文原文，按小节标题（`##`）取用；引用时写清小节名，方便对方回查。

## 5. 取证：先跑命令，再下判断

静态审查最容易犯的错是「凭印象断言工具行为」。下面这些命令给出的是硬事实，比推理可靠。全部 POSIX，装没装 `busybox` 都不影响前半段。

```sh
# shell：外部命令真的存在吗（别假设 toybox 有 seq / flock / stat -c）
for c in flock setsid nohup pgrep timeout seq stat readlink; do
  printf '%s: %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done

# shell：toybox 还是 busybox，以及某 applet 是否支持某个选项
ls -l /system/bin/toybox /system/bin/busybox 2>/dev/null
toybox 2>/dev/null | head -3

# 危险模式速查（命中不等于有 bug，但每一处都要人工看一眼）
grep -nE '(^|[^\\])>[[:space:]]*/dev/null[[:space:]]*2>&1[[:space:]]*&' -r . --include='*.sh'   # 后台且无 setsid
grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^"[:alnum:]_}]' -r . --include='*.sh'                     # 未加引号的变量
grep -nE 'rm[[:space:]]+-[rf]{1,2}[[:space:]]+"?\$' -r . --include='*.sh'                     # 变量参与删除路径
grep -nE 'cat[[:space:]]+.*\|[[:space:]]*(tr|sed|awk)' -r . --include='*.sh'                   # 可省掉的 fork
grep -nE 'while[[:space:]]+true|while[[:space:]]+:;' -r . --include='*.sh'                    # 常驻循环频率
```

```sh
# 前端：对比度、字号档、间距档这类数值不要目测，也不要在脑子里算
# UI审查 技能的 scripts/audit.js 是同一套取数器：
#   node -e "const a=require('<SKILL_DIR_UI>/scripts/audit.js'); console.log(a.auditContrast('#9aa0c0','#0f1220'))"
# 输出 7.24 就是实测值；> 4.5 正文达标，> 3 大字（>=24px 或 >=18.66px 且 700）达标
```

不要在本技能里重写一份对比度公式——两份实现迟早会算出两个数，那时就没有可信的一方了。

## 6. 三档怎么用

- `android/shell-magisk.md`：模块生命周期与时机、外部命令可用性、fork 与单例、备份/还原对称性、sysfs 写失败静默、noexec 约束。审 Magisk/KernelSU/APatch 模块脚本时**先读这份**。
- `android/ksu-webui.md`：`ksu.exec` 返回值形态、错误分支、执行成功不等于命令成功、DOM 取值方式、视口与缩放。
- `android/smali-apk.md`：寄存器宽度与 `/range`、`const/4` 边界、资源 ID 连带、manifest 运行时副作用、R8 混淆后的定位方式。

## 7. 明确不做

- **不改代码**。审查的产物是判断，不是补丁；要改另开任务，避免「边审边改」导致结论失去独立性。
- **不评格式**：缩进、行宽、命名偏好交给 linter 与 formatter。
- **不猜设备行为**：未经实测的 sysfs/内核/固件行为一律进「存疑」列。
- **不把上游档当本地规范**：上游是通用最佳实践，与项目既有约定冲突时，以项目约定为准，并指出冲突点。

## 8. 常见借口（自查用）

| 想法 | 事实 |
|---|---|
| 「这改动很小，不用审」 | 小改动同样能改坏备份路径、删除路径、权限。范围小 ≠ 风险小 |
| 「我边改边审更快」 | 改的人看不见自己的假设。要改就改完再另起一轮审 |
| 「跑起来没问题就是对的」 | 只在成功路径上跑过，说明失败路径从没被测过 |
| 「这段照着某项目抄的」 | 抄来的东西最容易被当成正确，也最容易缺上下文 |
| 「用户只问了 X，其他不归我管」 | 🔴 级问题一律越界上报，其余可以一句话带过 |

## 9. 目录与许可

```
SKILL.md                          本文件
references/upstream/              上游 30 篇 + cross-cutting 5 篇（英文原文，MIT）
references/upstream/SOURCE.txt    上游仓库与提交号、更新方法
references/android/               本技能自研三档（中文）
```

上游底稿：`awesome-skills/code-review-skill`（MIT，提交号见 SOURCE.txt）。
三档为自研，只写判定方法、不写具体机型结论——换设备不失真。