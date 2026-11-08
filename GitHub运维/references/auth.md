# 令牌（PAT）与鉴权

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/auth.md`

## 1. 为什么必须用 PAT

GitHub 早已关闭「账号 + 密码」的 HTTPS 推送。`git push` 想要密码时，你必须给一个
**Personal Access Token**（PAT）。SSH key 也能推，但手机端要管私钥、要配 `known_hosts`，
对一次性推送来说是多余环节——本技能只用 HTTPS + PAT。

同一个令牌同时供两条链路使用：`git push` 直接拿它做基本认证，`gh` 从 `GH_TOKEN`
环境变量读它调 REST。**不需要** `gh auth login`（那是交互式流程，还会把令牌写进
`~/.config/gh/hosts.yml`，proot 重装即丢且明文落盘）。

## 2. 两种 PAT 怎么选

| | classic（推荐） | fine-grained |
|---|---|---|
| 入口 | `https://github.com/settings/tokens` → Generate new token (classic) | 同页 → Fine-grained tokens |
| 前缀 | `ghp_` | `github_pat_` |
| 权限 | 勾选 `repo` 整块 | 逐项选：`Contents: Read and write` + `Administration: Read and write` |
| 能否创建仓库 | 能（`repo` 覆盖） | **必须** `Administration: Read and write` 且 Repository access 选 **All repositories** |
| 能否发 Release | 能 | 需 `Contents: Read and write`（上传资产走 contents 权限） |
| 能否删仓库 | **需额外勾 `delete_repo`**（只勾 `repo` 会 403） | 需 `Administration: Read and write` |
| 能否用 Gist | 能 | 需额外勾 `Gists` |
| 能否读 Actions 日志 | 能 | 需额外勾 `Actions: Read` |
| 能否改 PR/Issue | 能 | 需额外勾 `Issues: Read and write` / `Pull requests: Read and write` |
| 适合 | 手机上一把过、要建仓 + 推送 + 发包 + 协作 | 只推已存在的仓库、想严格限权 |

**踩坑提醒**：fine-grained 令牌如果选了「Only select repositories」，就**无法创建新仓库**
（因为新仓库此刻还不存在，不在白名单里），`POST /user/repos` 会返回 403。要么选 All repositories，
要么先在网页建好仓库、令牌只留 `Contents: Read and write`。

步骤（classic，约 2 分钟）：

1. 打开 `https://github.com/settings/tokens`
2. Generate new token → Generate new token (classic)
3. Note 填 `operit-gh`，Expiration 选 **7 days**
4. 勾 `repo`（要发 Gist 再勾 `gist`，要读 CI 日志再勾 `workflow`）
5. Generate token → 复制 `ghp_…`（**只显示一次**）

## 3. 令牌怎么用才不漏

```sh
export GH_TOKEN=ghp_xxxxxxxx              # 只进环境变量
sh ghenv.sh check                         # 先确认令牌可用（会打 LOGIN=）
sh ghrepo.sh repo "$P" 仓库名 public       # 脚本内部读，不进命令行参数
sh ghrepo.sh push "$P"
sh ghadm.sh pr-list owner/repo            # 管理动作同样只读环境变量
unset GH_TOKEN                            # 用完清掉
```

不要做的四件事：

- ❌ `git remote add origin https://ghp_xxx@github.com/u/r.git` —— 令牌会写进 `.git/config`，一直留在磁盘上
- ❌ `git config --global credential.helper store` —— 明文存 `~/.git-credentials`
- ❌ 把令牌写进脚本、README、`.env` 再提交
- ❌ 把令牌贴进聊天或截图里（会进日志与上下文）

本技能的实现：`origin` 永远是不含令牌的 `https://github.com/u/r.git`，`push` 时才用
`https://x-access-token:$TOKEN@github.com/u/r.git` 这种**一次性 URL**；脚本还会把输出里的
userinfo 段打码（`//***@`）后再打印。`gh` 侧只用 `GH_TOKEN` 环境变量，不碰 `gh auth login`。

延迟暴露的残余风险：带凭据的 URL 会短暂出现在 git 子进程的 argv 里（`ps` 可见）。
在单用户手机上这个窗口可以接受；多用户或服务器场景请改用 `GIT_ASKPASS`。

## 4. HTTP 状态码对照

| 状态 | 含义 | 处理 |
|---|---|---|
| 401 | 令牌无效 / 过期 / 已撤销 | 重新生成；确认没有多余空格或换行 |
| 403 | 权限不足，或 fine-grained 未覆盖该仓库/未选 All repositories | 换 classic + `repo`，或补 `Administration: Read and write` |
| 404 | 仓库不存在（或私有仓库看不见） | `POST /user/repos` 创建；仓库名不要带空格/中文 |
| 422 | 名字冲突、名字非法、**Release 的 tag 已存在** | 换名字；发 Release 时改用 `republish` |
| 429 | 触发速率限制 | 等窗口重置；`gh api rate_limit --jq .rate` 看剩余与重置时间 |
| 451 | 因法律原因不可用 | 换个仓库名/内容 |

本技能的脚本会把 401/403 归为退出码 3（凭据问题），把其余 4xx/5xx 与网络错误归为 4
（环境/网络问题）。看到 3 就换令牌，看到 4 就先查网络与仓库名，别盲目重试。

## 5. 令牌泄漏后的正确处置

1. 立刻到 `https://github.com/settings/tokens` **Revoke** 该令牌（删除文件、再提交一次都不能让它失效）；
2. 检查是否已进历史：`git log -S 'ghp_' --all`；
3. 若已推送，视为已泄漏，必须换新令牌；历史是否重写取决于仓库是否公开（本技能不提供改历史功能）。

## 6. 用完就撤

推送完成后建议直接删掉令牌（或在 7 天后自动过期）。下次再推时重新生成一个即可——
这比长期留一个 `repo` 全权限令牌在手机上安全得多。