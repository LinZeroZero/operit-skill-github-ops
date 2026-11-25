---
name: GitHub运维
description: 在 Operit(Android/proot) 上用 gh 管 GitHub：建仓推送、Release、PR/Issue、Actions、Gist；含 FUSE 上 git 写对象失败与分批推送。
---

最后验证: 2026-11-22
依赖版本: gh + git（未锁版本，先 `gh --version` 探测）

# GitHub 运维（Operit / Android）

两条链路共用同一个令牌：**git 管文件与提交，gh 管远端对象**。
`/sdcard` 是 noexec 挂载，所以所有脚本只能 `sh <脚本>` 调用，不能直接执行。

脚本目录：`/sdcard/Download/Operit/skills/GitHub运维/scripts/`

| 脚本 | 管什么 | 什么时候读它 |
|---|---|---|
| `ghenv.sh` | gh 安装/体检/恢复 | **每次开工第一步** |
| `ghrepo.sh` | 推送与发版（高频） | 把目录变成仓库、发包 |
| `ghadm.sh` | 仓库/PR/Issue/Actions/Gist（低频） | 推完之后的所有事 |
| `ghlib.sh` | 公共库（被上面三个 source） | 改退出码/闸门/探测逻辑时 |

## 0. 七条硬规则

1. **先 `sh ghenv.sh check`，再做任何事。** gh 不在或版本低于 2.45 时，
   PR/Issue/Actions/Gist 全部不可用——先修环境，别硬试。
2. **建仓必须 `core.createObject rename`。** `ghrepo.sh init` 会**无条件**写入这一项
   （不再靠探测文件系统类型决定要不要写），你手工建仓时也必须自己设。不设的话
   `git add` 报 `unable to write file .git/objects/xx/…: No such file or directory`，
   **报错路径看着像不存在，其实目录是好的**。根因见 `references/fuse-git.md`。
3. **令牌只从 `GH_TOKEN` 环境变量读：不落盘、也不进 argv。** 不写 remote URL、
   不写 `~/.git-credentials`、不写 `~/.config/gh/hosts.yml`、不 echo 进日志。
   `push` 靠 `GIT_ASKPASS` 把令牌交给 git，所以 `ps` 与命令行里都看不到它。用完 `unset`。
4. **大仓库分批推；破坏性操作要复述目标。**
   手机上一次推 2 万文件/200 MB，断网就得从头来；分批后已完成批次不用重来。
   删仓库/删 Gist 必须把目标名再写一遍（`gate_confirm`），不一致直接退出码 5。
5. **提 PR / 发版前，用目标分支（规则 6）的三点差异核对改动清单；交接文档里写的 base 一律当可疑。**
   `git fetch` 后跑 `git diff --stat origin/<目标分支>`（对工作区或分支头），数字必须对得上「你以为改了什么」。
   反例（2026-11 实测）：交接文档写的 base 已落后远端一整代，照它建分支提 PR，PR 页面的
   三点差异会把上游**已合并**的改动算成「删除」，合并即回退功能 —— 而页面看起来完全正常。
   判据：PR 的 `changed_files` / `additions` / `deletions` 必须与自己数的一致；对不上就是 base 错，
   把改动重放到 `origin/<目标分支>` 之上再提交（备份 → `reset --hard origin/<目标分支>` → 放回 → 逐文件比对 hash）。

6. **提 PR 前先确认仓库要哪个目标分支。`default_branch` 是「clone 落到哪」，不是「PR 该合到哪」。**
   按顺序取值，不要猜：
   1. 有 `CONTRIBUTING.md` / `.github/pull_request_template.md` → 照它写；
   2. 没有文档 → 数**最近一批 PR 的 base 分布**，实际执行的标准就在数据里：
      ```sh
      A="/sdcard/Download/Operit/skills/GitHub运维/scripts/ghadm.sh"
      sh "$A" api '/repos/<owner>/<repo>/pulls?state=all&per_page=20' \
        --jq '.[] | .base.ref' | sort | uniq -c | sort -rn
      ```
   3. 分布混杂 → 按多数派走，少数派当「例外」，不当反例。
   反例（2026-11-22 实测）：某仓库 `default_branch=main`，最近 15 个 PR 里 14 个 base=`dev`。
   按默认值提 PR 后被打回「目标分支错误」；善后更贵 —— `main` 与 `dev` 已分叉
   （`dev` 缺 `main` 上 10 个提交、8 个 `strings.xml` 两边内容不同），只改 base 会让三点差异
   把别人的改动算进来，必须把补丁重放到 `dev` 上（流程见 `references/pr-base.md`）。

7. **PR 正文不许一句「修复问题」。** 没有模板时按四栏写：
   `## 改了什么`（文件级清单，条目要对得上 `git diff --stat`）/ `## 为什么`（要解决的现象）/
   `## 怎么验证`（一条别人自己能跑的命令 + 预期输出）/ `## 怎么回退`（revert 哪个 commit、恢复哪个文件）。
   `pr-create` 的正文传 `-` 会自动补空骨架；正文非空但一个 `##` 标题都没有会被拒（退出码 1）。
   只查「有没有标题」，不查栏数与措辞 —— 内容质量机器判不了，硬判只会让人学会应付格式。
   仓库有 `CONTRIBUTING.md` / `.github/pull_request_template.md` 时按规则 6 照它写，优先于本骨架。

## 1. 主链路一：把目录变成仓库并发版

```sh
S="/sdcard/Download/Operit/skills/GitHub运维/scripts"
P="/sdcard/your-project"

sh "$S/ghenv.sh"  check                              # 1. 环境体检，必须全绿
sh "$S/ghrepo.sh" check "$P"                          # 2. 只读体检：体积/文件数/大文件/连通性
sh "$S/ghrepo.sh" init  "$P"                          # 3. 建仓 + 写死 FUSE 必需 config
sh "$S/ghrepo.sh" stage "$P"                          # 4. 省略路径 = 全部；大仓库按批传路径
sh "$S/ghrepo.sh" commit "$P" "提交说明"
export GH_TOKEN=ghp_xxxxxxxx                          # 5. 令牌只在这一处出现
sh "$S/ghrepo.sh" repo  "$P" my-repo public           # 6. 建远端仓库（已存在则复用）+ 设 origin
sh "$S/ghrepo.sh" push  "$P"                          # 7. 推送当前分支
```

分批范式（大仓库照抄）：

```sh
sh "$S/ghrepo.sh" stage "$P" README.md dist/ && sh "$S/ghrepo.sh" commit "$P" "docs + artifact" && sh "$S/ghrepo.sh" push "$P"
sh "$S/ghrepo.sh" stage "$P" src/            && sh "$S/ghrepo.sh" commit "$P" "source tree"     && sh "$S/ghrepo.sh" push "$P"
```

### 发版（push ≠ 发布包）

push 完仓库页只有源码，Releases 是空的。要「别人点一下就能下」必须建 Release：

```sh
sh "$S/ghrepo.sh" release "$P" v2.0.18 'v2.0.18 中文去广告' "$P/app.apk" /sdcard/notes.md
# 输出 TAG= / RELEASE_URL= / ASSET_URL= / ASSET_SIZE=
```

- 一个 tag 只能挂一个 Release，重复创建会 422（脚本提前探测并直接点明）；
- 不需要手工 `git tag`：GitHub 按 `tag_name` 自动建 tag，指向当前分支；
- 说明文件可省略，缺省用「构建自 <短提交号> + 最近提交标题」。
- **说明里的每一条都要能在 `git diff origin/<目标分支>` 里指到对应行**（发版走默认分支时即 `origin/main`；PR 目标是别的分支就换成那个分支，见规则 6）。只在工作区存在过的
  中间态、交接文档里抄来的条目与数值，都不算数（实测：某条「删除诊断写文件」在三个分支
  全都不存在，却被写成 Fixed；同一批交接里的 so 尺寸也是笔误 —— 读者会去历史里翻，翻不到就是误导）。
  同理，附件数值要回读：`ls -l` 的字节数与 `sha256sum` 当场核对，别从别处抄。

**已经发过、只想换包**：用 `republish`（tag 不变，同名资产原地覆盖）：

```sh
sh "$S/ghrepo.sh" republish "$P" v2.0.18 '新标题' "$P/新包.apk" /sdcard/notes.md
# 输出 ASSET_MODE=clobber（同名覆盖，旧下载链接仍然有效）
```

与老实现的差别：以前是「先删旧资产再传新的」，旧文件名的链接会 404；
现在用 `gh release upload --clobber`，**同名覆盖、旧链接不失效**。

## 2. 一个目录下多个技能：一技能一仓

技能目录下常有好几个技能。**别把父目录做成一个仓库**：历史混在一起，改 A 的提交里会掺着 B 的发布物，
发包时还得手工挑文件。正确形态是**每个技能目录各自是仓库**：

```
/sdcard/Download/Operit/skills/     ← 不是仓库，没有 .git
├── GitHub运维/                     ← 自己是仓库
│   ├── .git  README.md  install.sh  SKILL.md  references/  scripts/
└── APK逆向改包/                    ← 自己是仓库
    └── .git  README.md  install.sh  SKILL.md  references/
```

### 从混合仓库拆出来（保留历史）

`subtree split` 按目录前缀重写历史，每个技能得到一条干净的提交链：

```sh
git clone --no-hardlinks /sdcard/Download/Operit/skills /root/split   # 先落到 ext4，FUSE 上拆很慢
cd /root/split
git config core.quotePath false            # 硬要求，见下方说明
git subtree split --prefix="GitHub运维"  -b ops
git subtree split --prefix="APK逆向改包" -b apk
```

`core.quotePath false` 不能省。默认设置下 git 把中文路径输出成八进制转义，`subtree split`
拿它跟真名比较直接断言失败：`assertion failed: test "GitHub350277220347273264" = GitHub运维`。

### 每个技能目录各自成仓

```sh
D=/sdcard/Download/Operit/skills
cd "$D/GitHub运维"
git init -q -b main
git config core.createObject rename     # FUSE 必需（规则 2），ext4 上设了也无害
git config core.fileMode false          # /sdcard 上 mode 不可靠，防它制造噪音改动
git remote add origin https://github.com/<owner>/operit-skill-github-ops.git
git fetch -q origin && git reset --hard origin/main
```

之后就是第 1 节那套 `stage / commit / push`，`P` 换成技能目录即可，各技能互不影响。

### 发布物：顶层必须是中文技能名

Operit 靠目录名认技能，解压后要得到 `skills/<技能名>/SKILL.md`，所以打包时顶层目录写成技能名：

```sh
tar -czf /root/github-ops.tar.gz --exclude='GitHub运维/.git' \
  -C /sdcard/Download/Operit/skills 'GitHub运维'
tar -tzf /root/github-ops.tar.gz | grep -c '\.git/'     # 必须是 0
```

`--exclude` 一定要带：FUSE 的 `.git` 里有 `.l2s.tmp_*` 符号链接，`cp -a` 会刷一屏
`Too many levels of symbolic links`，产物还会白白大出一倍。

### 三个真踩过的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| push 报成功，但远端 `main` 没变 | `push` 推的是 **HEAD 所在分支**，当时停在 `ops` 分支上 | 先 `git -C "$P" branch --show-current` 确认；切回 `main` 重推，再删掉多余分支：`sh "$A" api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>` |
| 建了新仓库，旧仓库还挂着两个技能 | 只建了新的，旧的没处理 | 用改名而不是删：`sh "$A" api -X PATCH repos/<owner>/<old> -f name=<new>`，历史与旧 URL 都保留 |
| 拆完技能文档里还写着旧仓库名 | 文档没跟着改 | `grep -rIn '<旧仓库名>'` 清干净；别指望旧 URL 靠 301 兜住 |

## 3. 主链路二：日常运维（`ghadm.sh`）

仓库参数一律是 `owner/repo`；也可以写 `.` 表示「用当前目录的 origin」。

```sh
A="/sdcard/Download/Operit/skills/GitHub运维/scripts/ghadm.sh"
```

| 想做什么 | 一条命令 |
|---|---|
| 看仓库概况 | `sh "$A" repo-view owner/repo` |
| 列我的仓库 | `sh "$A" repo-list 30` |
| 改描述/可见性/topics | `sh "$A" repo-edit owner/repo "新描述" private bug,android` |
| 克隆 | `sh "$A" repo-clone owner/repo /sdcard/your-project/x` |
| 提 PR（head 取当前分支） | `sh "$A" pr-create "$P" "标题" "正文或 -" <目标分支>` ← 传 `-` 自动补四栏骨架 |
| 列/看 PR | `sh "$A" pr-list owner/repo open 20` / `pr-view owner/repo 3` |
| 合并 PR | `sh "$A" pr-merge owner/repo 3 squash` |
| 关 PR / 评论 | `sh "$A" pr-close owner/repo 3` / `pr-comment owner/repo 3 "正文"` |
| 提 Issue | `sh "$A" issue-create owner/repo "标题" "正文" bug,docs` |
| 列/关 Issue | `sh "$A" issue-list owner/repo open 20` / `issue-close owner/repo 5` |
| 看 CI 运行 | `sh "$A" ci-list owner/repo 10` / `ci-view owner/repo 123456` |
| 触发 workflow | `sh "$A" ci-run owner/repo build.yml main` |
| 拉 CI 日志 | `sh "$A" ci-logs owner/repo 123456 /sdcard/ci.log` |
| 发 Gist | `sh "$A" gist-create "描述" /sdcard/x.sh` |
| 列/看/取 Gist | `sh "$A" gist-list` / `gist-view <id>` / `gist-get <id> /sdcard/x.sh` |
| 任意 API 兜底 | `sh "$A" api repos/owner/repo --jq .stargazers_count` |
| **删仓库** | `sh "$A" repo-delete owner/repo owner/repo` ← 第二个参数是复述 |
| **删 Gist** | `sh "$A" gist-delete <id> <id>` ← 同上 |

`pr-create` 的 base 必须显式给，且要先按规则 6 确认目标分支，别照抄示例里的占位符。
正文同理：不确定写什么就传 `-`，脚本补骨架；一句话正文（无 `##` 标题）会被拒。

细节：删除仓库需要令牌额外带 `delete_repo` scope，只勾 `repo` 会 403。
`issue-create` 的标签由 GitHub 自己创建——**标签名拼错不会报错**，只会静默多出一个新标签
（实测确认，见 `references/gh-json-fields.md` §3）。
完整矩阵见 `references/destructive.md`。

## 4. gh 环境（重装 proot 之后先看这段）

`gh` 装的是官方 **linux_arm64 静态包**，位置 `/root/tools/gh/bin/gh`；
tar.gz 备份在技能目录 `vendor/` 下，重装后一条命令恢复，**不需要 apt、不需要联网**：

```sh
sh /sdcard/Download/Operit/skills/GitHub运维/scripts/ghenv.sh install
```

为什么不用 apt：源里的版本通常落后好几条 minor（`--jq`/`--clobber` 行为会不一致），
而且重装后得先把 apt 源修成国内镜像才能装。详见 `references/toolchain-gh.md`。

## 5. 症状速查表

| 症状 | 处理 |
|---|---|
| `unable to write file .git/objects/…` | 忘了 `core.createObject rename`，见规则 2 |
| `detected dubious ownership` | `git config --global --add safe.directory '*'`（脚本 init 已自动登记两种路径写法） |
| 脚本退出码 2、报没有 gh | `sh ghenv.sh install`（离线解压 vendor 包） |
| 脚本退出码 3 | 令牌无效/权限不足，换令牌；删仓库还要 `delete_repo` |
| 脚本退出码 5 | 破坏性操作没复述目标，按提示把目标名再写一遍（第二个参数，不是 `--confirm` 开关） |
| `HTTP 422` / `Validation Failed` | 退出码 **1**：参数或预条件冲突（名字非法、tag 已存在、字段不合法），不是网络问题 |
| `HTTP 422` 且消息含 `is not a boolean` | `-f` 只传字符串，布尔/数字参数要用 `-F`，见 `references/gh-json-fields.md` §0 |
| PR 被要求「把 base 改成 xxx」 | 提 PR 前没确认目标分支，见规则 6 与 `references/pr-base.md` |
| CI 显示 `action_required`、jobs 数为 0 | 不是失败：首次贡献者的 run 需维护者 Approve and run；`pull_request.branches` 不含目标分支时压根不触发 |
| `HTTP 404` 但网页有这仓库 | 私有仓库对无权令牌返回 404，是权限问题不是不存在 |
| `Recv failure` / `HTTP 502` / push 卡住 | 降 HTTP/1.1、加 postBuffer、走本机代理，重跑可续传 |
| `remote: File … exceeds 100.00 MB` | 该文件超硬上限，移出仓库或改 LFS（本技能不含 LFS） |
| `non-fast-forward` / `fetch first` | 先 `git pull --rebase`，不要 `push -f` |
| 推送后文件数对不上 | `git check-ignore -v <path>` 看 `.gitignore` |
| PR diff 里出现大量「删除」，与自己改的内容不符 | base 落后远端（三点差异用的是旧 merge-base）→ 改动重放到 `origin/<目标分支>` 再提，见规则 5、规则 6 |
| 本地 `git diff` 正常，PR 里却变了样 | 本地分支/工作区与远端目标分支不同步 → 一切都以 `origin/<目标分支>` 为基准比，不看本地 HEAD |
| 发 Release 报 `already_exists` | 退出码 1；同 tag 只能一个 Release，改用 `republish` |
| 命令卡住无输出 | gh 想开编辑器/分页器。本技能已 export `GH_PROMPT_DISABLED=1`、`GIT_EDITOR=true`、`GIT_TERMINAL_PROMPT=0`、`*_PAGER=cat`（`ghrepo.sh doctor` 的 `NOINTERACT=` 一行可自检）；手敲 gh 时也得自己加 |
| 刚创建的 issue/PR 立刻 list 查不到 | 列表接口有秒级最终一致性延迟，看创建返回的编号，或隔几秒再查 |

更多分档（本地 / gh 自身 / 网络 / GitHub 侧 / 推完不对）见 `references/troubleshoot.md`。

## 6. 边界（明确不做，避免误期待）

- **Projects（v2 看板）**：主走 GraphQL + node_id，成本远高于收益
- Discussions、Sponsors、Packages、Org/Teams 批量成员管理
- 自建 Actions runner、生成 workflow 文件
- Git LFS 服务端配额管理（只保留「>100 MB 必须拆或 LFS」的判定与提示）
- 远端历史改写与常规 force push（例外两条：① 刚建的空仓库 + `operit-push` 占位作者，
  可 `commit --amend --reset-author` 后覆盖一次，`repo` 子命令正常情况会自动改掉占位身份；
  ② **自己 fork 上 PR 头分支**因目标分支变更而重放提交 —— 必须记下旧 sha 作回退，
  不得用于他人分支或受保护分支，流程与回退命令见 `references/pr-base.md`）
- `gh auth login` 交互登录、浏览器 OAuth

## 7. 参考文件（绝对路径，直接 read_file 打开）

- `/sdcard/Download/Operit/skills/GitHub运维/references/toolchain-gh.md` —— gh 装哪、怎么装、怎么恢复、版本策略
- `/sdcard/Download/Operit/skills/GitHub运维/references/fuse-git.md` —— FUSE 上 add 失败的根因、两条解法、实测基线
- `/sdcard/Download/Operit/skills/GitHub运维/references/auth.md` —— 令牌怎么选、权限最小集、401/403/404/422 对照
- `/sdcard/Download/Operit/skills/GitHub运维/references/troubleshoot.md` —— 症状 → 原因 → 处理（五档分类）
- `/sdcard/Download/Operit/skills/GitHub运维/references/gh-json-fields.md` —— 每个命令依赖哪些字段（版本敏感点清单）
- `/sdcard/Download/Operit/skills/GitHub运维/references/destructive.md` —— 破坏性操作矩阵与闸门规则
- `/sdcard/Download/Operit/skills/GitHub运维/references/sanitize.md` —— 仓库转 public 前的脱敏流程（什么该改、什么该留、远端复查）
- `/sdcard/Download/Operit/skills/GitHub运维/references/pr-base.md` —— 目标分支确认、分叉判定、重放到目标分支与回退
- `/sdcard/Download/Operit/skills/GitHub运维/scripts/` —— 四个脚本的实现

## 8. 使用前自检

**覆盖**：proot 内 gh/git 建仓推送、Release、PR/Issue、Actions、Gist、FUSE 写对象失败、分批推送、转 public 前脱敏。

**不覆盖**：GitLab / Gitee、网页端操作、仓库内代码质量（交「代码审查」技能）、组织权限与密钥治理设计。

**开工前复核**：单批推送量与实测一致；破坏性操作先过 `references/destructive.md` 闸门；转 public 前必走 `references/sanitize.md`。