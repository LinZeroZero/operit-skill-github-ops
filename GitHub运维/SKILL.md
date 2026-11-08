---
name: GitHub运维
description: 在 Operit(Android/proot) 上用 gh 管 GitHub：建仓推送、Release、PR/Issue、Actions、Gist；含 FUSE 上 git 写对象失败与分批推送。
---

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

## 0. 四条硬规则

1. **先 `sh ghenv.sh check`，再做任何事。** gh 不在或版本低于 2.45 时，
   PR/Issue/Actions/Gist 全部不可用——先修环境，别硬试。
2. **项目在 `/sdcard` 下，建仓必须 `core.createObject rename`。**
   不设的话 `git add` 报 `unable to write file .git/objects/xx/…: No such file or directory`，
   **报错路径看着像不存在，其实目录是好的**。根因见 `references/fuse-git.md`。
3. **令牌只从 `GH_TOKEN` 环境变量读，绝不落盘。** 不写 remote URL、不写 `~/.git-credentials`、
   不写 `~/.config/gh/hosts.yml`、不 echo 进日志。用完 `unset`。
4. **大仓库分批推；破坏性操作要复述目标。**
   手机上一次推 2 万文件/200 MB，断网就得从头来；分批后已完成批次不用重来。
   删仓库/删 Gist 必须把目标名再写一遍（`gate_confirm`），不一致直接退出码 5。

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

**已经发过、只想换包**：用 `republish`（tag 不变，同名资产原地覆盖）：

```sh
sh "$S/ghrepo.sh" republish "$P" v2.0.18 '新标题' "$P/新包.apk" /sdcard/notes.md
# 输出 ASSET_MODE=clobber（同名覆盖，旧下载链接仍然有效）
```

与老实现的差别：以前是「先删旧资产再传新的」，旧文件名的链接会 404；
现在用 `gh release upload --clobber`，**同名覆盖、旧链接不失效**。

## 2. 主链路二：日常运维（`ghadm.sh`）

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
| 提 PR（head 取当前分支） | `sh "$A" pr-create "$P" "标题" "正文" main` |
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

细节：删除仓库需要令牌额外带 `delete_repo` scope，只勾 `repo` 会 403。
完整矩阵见 `references/destructive.md`。

## 3. gh 环境（重装 proot 之后先看这段）

`gh` 装的是官方 **linux_arm64 静态包**，位置 `/root/tools/gh/bin/gh`；
tar.gz 备份在技能目录 `vendor/` 下，重装后一条命令恢复，**不需要 apt、不需要联网**：

```sh
sh /sdcard/Download/Operit/skills/GitHub运维/scripts/ghenv.sh install
```

为什么不用 apt：源里的版本通常落后好几条 minor（`--jq`/`--clobber` 行为会不一致），
而且重装后得先把 apt 源修成国内镜像才能装。详见 `references/toolchain-gh.md`。

## 4. 症状速查表

| 症状 | 处理 |
|---|---|
| `unable to write file .git/objects/…` | 忘了 `core.createObject rename`，见规则 2 |
| `detected dubious ownership` | `git config --global --add safe.directory '*'`（脚本 init 已自动登记两种路径写法） |
| 脚本退出码 2、报没有 gh | `sh ghenv.sh install`（离线解压 vendor 包） |
| 脚本退出码 3 | 令牌无效/权限不足，换令牌；删仓库还要 `delete_repo` |
| 脚本退出码 5 | 破坏性操作没复述目标，按提示把目标名再写一遍 |
| `HTTP 404` 但网页有这仓库 | 私有仓库对无权令牌返回 404，是权限问题不是不存在 |
| `Recv failure` / `HTTP 502` / push 卡住 | 降 HTTP/1.1、加 postBuffer、走本机代理，重跑可续传 |
| `remote: File … exceeds 100.00 MB` | 该文件超硬上限，移出仓库或改 LFS（本技能不含 LFS） |
| `non-fast-forward` / `fetch first` | 先 `git pull --rebase`，不要 `push -f` |
| 推送后文件数对不上 | `git check-ignore -v <path>` 看 `.gitignore` |
| 发 Release 报 `already_exists` | 同 tag 只能一个 Release，改用 `republish` |
| 命令卡住无输出 | gh 想开编辑器/分页器；本技能已强制非交互，手敲时加 `GH_PAGER=cat` 与 `--body ""` |
| 刚创建的 issue/PR 立刻 list 查不到 | 列表接口有秒级最终一致性延迟，看创建返回的编号，或隔几秒再查 |

更多分档（本地 / gh 自身 / 网络 / GitHub 侧 / 推完不对）见 `references/troubleshoot.md`。

## 5. 边界（明确不做，避免误期待）

- **Projects（v2 看板）**：主走 GraphQL + node_id，成本远高于收益
- Discussions、Sponsors、Packages、Org/Teams 批量成员管理
- 自建 Actions runner、生成 workflow 文件
- Git LFS 服务端配额管理（只保留「>100 MB 必须拆或 LFS」的判定与提示）
- 远端历史改写与常规 force push（唯一例外：刚建的空仓库 + `operit-push` 占位作者，
  可 `commit --amend --reset-author` 后覆盖一次；`repo` 子命令正常情况会自动改掉占位身份）
- `gh auth login` 交互登录、浏览器 OAuth

## 6. 参考文件（绝对路径，直接 read_file 打开）

- `/sdcard/Download/Operit/skills/GitHub运维/references/toolchain-gh.md` —— gh 装哪、怎么装、怎么恢复、版本策略
- `/sdcard/Download/Operit/skills/GitHub运维/references/fuse-git.md` —— FUSE 上 add 失败的根因、两条解法、实测基线
- `/sdcard/Download/Operit/skills/GitHub运维/references/auth.md` —— 令牌怎么选、权限最小集、401/403/404/422 对照
- `/sdcard/Download/Operit/skills/GitHub运维/references/troubleshoot.md` —— 症状 → 原因 → 处理（五档分类）
- `/sdcard/Download/Operit/skills/GitHub运维/references/gh-json-fields.md` —— 每个命令依赖哪些字段（版本敏感点清单）
- `/sdcard/Download/Operit/skills/GitHub运维/references/destructive.md` —— 破坏性操作矩阵与闸门规则
- `/sdcard/Download/Operit/skills/GitHub运维/references/sanitize.md` —— 仓库转 public 前的脱敏流程（什么该改、什么该留、远端复查）
- `/sdcard/Download/Operit/skills/GitHub运维/scripts/` —— 四个脚本的实现