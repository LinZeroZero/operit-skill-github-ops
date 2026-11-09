# Operit 技能备份

Operit（Android / proot）里的自定义 skill，纯备份用途。

## 内容

| 目录 | frontmatter `name` | 作用 |
|---|---|---|
| `GitHub运维/` | `GitHub运维` | 用 gh + git 管 GitHub：建仓推送、Release、PR/Issue/Actions/Gist；含 FUSE 上 git 写对象失败的必设 config |
| `APK逆向改包/` | `APK逆向改包` | 反编译 APK、改默认值/开关/常量/资源/标识，再回编译重签名并验证 |
| `代码审查/` | `代码审查` | 四阶段流程 + 严重度分级，产出带 `file:line` 与可追溯依据的 finding；含 shell/Magisk、KSU WebUI、smali 三档与上游 30 篇语言档 |
| `UI审查/` | `UI审查` | 按层级→间距→排版→色彩→深度→图像→收尾七步扫查界面，每条 finding 挂规则号（§）、严重度与实测数值；只诊断不改代码 |

`SandboxPackage_DEV`（29 MB 示例包）暂未入库，见 `.gitignore`——想备份就删掉里面那一行再 commit。

## 恢复方式

Operit 的技能目录固定为 `/sdcard/Download/Operit/skills/<skill_name>/`，
且目录名**必须**与 `SKILL.md` frontmatter 里的 `name` 一致，否则包管理会报「未找到 SKILL.md」。

```sh
cd /sdcard/Download/Operit/skills
git clone https://github.com/LinZeroZero/operit-skills.git /tmp/sk
cp -r /tmp/sk/GitHub运维 /tmp/sk/APK逆向改包 /tmp/sk/代码审查 /tmp/sk/UI审查 .
rm -rf /tmp/sk
```

仓库是 **Public**，直接 `git clone` 即可，无需令牌：
`git clone https://github.com/LinZeroZero/operit-skills.git`

`/sdcard` 是 noexec 挂载，仓库内所有脚本只能 `sh <脚本路径>` 调用，不能 `./脚本`。

## 依赖

- **GitHub运维**：gh 2.45+。仓库内 `GitHub运维/vendor/gh_2.103.3_linux_arm64.tar.gz` 可离线安装，
  细节见 `GitHub运维/references/toolchain-gh.md`；git 需 ≥ 2.40。
- **APK逆向改包**：Operit 的 `apk_reverse` 包 + proot 内 apktool / jadx / aapt2，
  版本与路径见 `APK逆向改包/references/toolchain-apk_reverse.md`。
- **代码审查**：无第三方运行时依赖，上游 30 篇 + cross-cutting 5 篇规则档已内置，断网可用。
  `browser` / `code_runner` / `git` 等只在探测到时才启用增强路径。
- **UI审查**：同样零依赖。取数脚本 `UI审查/scripts/audit.js` 可三处复用——
  `browser` 包的 `evaluate`、任意浏览器控制台粘贴、以及 `node` 直接 `require` 纯函数。
  没有 `browser` 包时自动降级为静态 CSS 取数，并在 finding 里标注"取数方式"。

## 注意

- 技能目录在 `/sdcard` 上，会被部分清理类 App 当垃圾扫掉；`.git` 同样风险。定期 `git add -A && commit && push` 做增量备份。
- 只有 `GitHub运维` 需要令牌，且只走 `GH_TOKEN` 环境变量；本仓库内不含任何明文令牌或私钥。
  其余技能不含凭据，也没有联网依赖。