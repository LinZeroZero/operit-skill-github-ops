# 症状 → 原因 → 处理

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/troubleshoot.md`

先记住退出码，能省一半排查时间：
`1` 用法错或参数/预条件冲突 · `2` 环境（无 gh / 目录不存在 / 不是仓库）· `3` 令牌 · `4` 网络或远端 · `5` 闸门未过。

## A. 本地（git 与文件系统）

### `error: unable to write file .git/objects/45/b983…: No such file or directory`
**原因**：仓库在 `/sdcard`（FUSE），git 用 `link()` 落对象，proot 的 link2symlink 在 FUSE 上失败。
**处理**：`git config core.createObject rename`。目录本身是好的，不要删 `.git` 重建。
细节见 `fuse-git.md`。

### `fatal: detected dubious ownership in repository at '/sdcard/…'`
**原因**：proot 内 uid=0，仓库属主是 Operit 的 App uid，git 拒绝在「别人的仓库」里干活。
**处理**：`git config --global --add safe.directory '*'`，
或精确登记两种路径写法：
```sh
git config --global --add safe.directory /sdcard/your-project
git config --global --add safe.directory /storage/emulated/0/your-project
```
（git 比较的是 realpath，两种写法的字符串不同。）

### `fatal: --local can only be used inside a git repository`
**原因**：通常不是命令写错，而是上一行的 dubious ownership 让 git 认为「不在仓库里」。
先解决 ownership，再看这条。

### 满屏 `warning: garbage found: …/.l2s.tmp_obj_*`
**原因**：proot link2symlink 的临时文件清理残留（多见于 `.git` 放在 f2fs 的分离布局）。
**处理**：`git gc --prune=now`，或只删这些临时文件：
```sh
find "$DIR/.git/objects" -name '.l2s.tmp_obj_*' -delete
```
不影响对象完整性，`git fsck` 能过就不用管。

### git 操作特别慢（几万文件）
**原因**：FUSE 上逐个文件 stat 很慢，且几万个 loose object 让后续操作更慢。
**处理**：按目录分批 stage + commit；阶段性 `git gc` 打包 loose object；
或改用「`.git` 放 `/root`、work-tree 指 `/sdcard`」的分离布局（`fuse-git.md` 解法二）。

## B. gh 自身

### `gh: command not found` / 脚本退出码 2
**原因**：proot 被重装、或换了设备，`/root/tools/gh` 丢了。
**处理**：`sh ghenv.sh install`——从技能目录 `vendor/` 里的官方包离线解压，不联网、不 apt。

### 报 `HTTP 404` 但网页上明明有这个仓库
**原因**：九个里有十个是**权限**而不是不存在：私有仓库对无权令牌返回 404 而非 403，
这是 GitHub 的刻意设计（不泄露私有资源是否存在）。
**处理**：确认令牌勾了 `repo`；fine-grained 令牌确认选的是 All repositories。

### `HTTP 401: Bad credentials`
**原因**：令牌过期/被撤销/粘错（含多余换行或空格）。
**处理**：重新生成，`export GH_TOKEN=...` 后跑 `sh ghenv.sh check` 确认 `LOGIN=` 有值。

### `HTTP 403: Resource not accessible by personal access token`
**原因**：权限不够。Gist 要 `gist`，Actions 日志要 `workflow`，改 PR/Issue 要对应写权限。
**处理**：按 `auth.md` 第 2 节的表补权限；嫌麻烦就换 classic + `repo`。

### `Unknown JSON field: "xxx"`
**原因**：用了 `gh xxx --json`，而该字段名在你这个 gh 版本里不存在。
**处理**：本技能脚本刻意用 `gh api` + REST 字段，不依赖 `--json` 字段集。
自己手写时改用 `gh api repos/o/r --jq '<表达式>'`。

### 命令「卡住不动」，没有任何输出
**原因**：gh 试图打开编辑器或分页器。手机终端没有可用 `$EDITOR`，于是无限等待。
**处理**：会写正文的命令必须给全参数（`pr-create` 的标题+正文、`pr-merge` 的合并方式）。
本技能脚本已 export `GH_PROMPT_DISABLED=1`、`GIT_EDITOR=true`、`EDITOR=true`、
`GIT_TERMINAL_PROMPT=0`、`GH_PAGER/PAGER/GIT_PAGER=cat`，需要交互时 gh 会直接报错而不是等输入；
`sh ghrepo.sh doctor <DIR>` 的 `NOINTERACT=` 行可以自检这些值是否生效。
自己手敲 gh 时同样要带上这些，并给全 `--body ""`。

### `unknown flag: --secret`（gh gist create）
**原因**：`gh gist create` 没有 `--secret`。gist **默认就是 secret**。
**处理**：去掉 `--secret`；要公开才加 `--public`。本技能 `gist-create` 已经不含该 flag。

### `--yes required when not running interactively`（gh gist delete 等）
**原因**：非交互环境里 gh 拒绝「自动确认删除」。
**处理**：加 `--yes`。本技能的做法是「复述闸门（语义确认）+ `--yes`（机器确认）」两道都过，
闸门不一致时连请求都不发。

### 刚创建的对象，立刻 `list` 查不到
**原因**：GitHub 列表接口有**秒级最终一致性延迟**。实测建 issue 后立即 `issue-list` 返回空，
隔几秒再查就正常；单对象接口（`repos/o/r/issues/3`）则是立即可见的。
**处理**：创建成功后**不要立刻用列表校验**，直接看创建接口返回的 `NUMBER`/`ID`；
确需列表确认就等几秒。这不是脚本 bug，别去改 jq。

## C. 网络与推送

### `Recv failure: Connection reset by peer` / `RPC failed; HTTP 502` / push 卡住
**原因**：手机网络跨境链路抖动，或 HTTP/2 在中间设备上断流。
**处理**：
```sh
git config http.version HTTP/1.1
git config http.postBuffer 524288000
git config http.lowSpeedLimit 1000
git config http.lowSpeedTime 60
```
仍失败走代理（Clash 与本机同网络命名空间，`127.0.0.1` 可直接用）：
```sh
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
```
**重跑即可续传**：已上传的对象不会重传，不用从头开始。

### `remote end hung up unexpectedly`（大仓库）
**原因**：单次传输过大被中断。
**处理**：分批 push（每批一个 commit），或 `git config pack.windowMemory 64m`、
`git config pack.compression 0`（换速度，体积略大）。

### `fatal: the remote end hung up unexpectedly` + `index-pack failed`
**原因**：内存不足（手机上 pack 大仓库吃内存）。
**处理**：`git config pack.threads 1`，`git config pack.deltaCacheSize 32m`，再重试。

### 推送中断后如何确认状态
```sh
git -C "$DIR" log --oneline -1
git -C "$DIR" ls-remote origin           # 看远端到底有没有这个提交（不带令牌，仅公开仓库可用）
```
私有仓库用 `sh ghrepo.sh doctor "$DIR"` 看本地状态，再重新 `push`。

## D. GitHub 侧拒绝

### `remote: error: GH001 / GH013`
**原因**：GH001 是大文件；GH013 是仓库规则（如要求签名提交、push protection 命中密钥）。
**处理**：读完整报错里给的链接；push protection 命中就撤销该密钥并把它移出内容。

### `remote: File xxx is 105.00 MB; this exceeds GitHub's file size limit of 100.00 MB`
**原因**：单文件超 100 MB 硬上限（>50 MB 会先警告）。
**处理**：把该文件移出仓库（`.gitignore`）、拆分，或改 Git LFS（本技能不含 LFS 配置）。

### `! [rejected] main -> main (non-fast-forward)`
**原因**：远端有你本地不认识的提交（比如网页上改过 README）。
**处理**：`git pull --rebase origin main` 后重推。**不要 `push -f`**，会覆盖别人的提交。

### `Password authentication is not supported` / 反复要密码
**原因**：给了账号密码而不是 PAT，或令牌失效。
**处理**：确认 `export GH_TOKEN=ghp_…`，用 `sh ghrepo.sh push`（内部用一次性 URL 鉴权）。

### 发 Release 报 `422 Validation Failed / already_exists / tag_name`
**原因**：同一个 tag 只能挂一个 Release，仓库里已有 `v1.0` 之类的 Release。
注意退出码是 **1**（参数/预条件冲突），不是 4——看到 1 不要往网络上查。
**处理**：换 tag，或用 `sh ghrepo.sh republish`（原位替换资产 + 更新说明）。

### 上传资产报 `422 already_exists`（同名资产重复）
**原因**：`gh release upload` 默认不覆盖同名资产。
**处理**：本技能的 `release` / `republish` 都带 `--clobber`，同名原地覆盖，不会堆两份。
自己手敲 gh 时记得加 `--clobber`。

## E. 推完了但看起来不对

### 网页上文件数比本地少
1. `.gitignore` 把目录整体忽略了：`git -C "$DIR" check-ignore -v 某文件`；
2. 那个目录在上一批 commit 里没被 stage：`git -C "$DIR" status --short | head`；
3. 推的不是你以为的分支：`git -C "$DIR" branch -vv`。

### 网页上看不到 README
文件名必须是 `README.md`（大小写敏感），且在仓库根目录；GitHub 只渲染根目录或 `docs/` 的 README。

### Release 里看不到新包
先跑 `sh ghrepo.sh assets "$DIR" <TAG>` 看资产到底在不在、有几个。
用 `--clobber` 重发后**旧下载链接仍然有效**（同名覆盖）；只有换了文件名才会出现新旧两份。

### 中文文件名变乱码
`git config core.precomposeUnicode true`（macOS 场景常见；Android 一般不需要）。
URL 里出现中文请让 git 自行编码，不要手写 `%E4%B8%AD`。

## F. 手机特有的两个隐性事故

1. **屏幕熄灭 → 网络挂起 → push 静默中断**：长时间 push 时保持前台/常亮，或分批减小单批体积。
2. **`/sdcard` 被清理工具扫描**：`.git` 目录在 `/sdcard` 上，部分清理类 App 会把 `.git` 当垃圾删除；
   同理，**技能目录本身在 `/sdcard/Download/Operit/skills/` 下也会被误删**——删了就用本对话里的文件重建，
   或把 skill 目录另存一份备份（`vendor/` 里的 gh 包同理，丢了要重新下载）。