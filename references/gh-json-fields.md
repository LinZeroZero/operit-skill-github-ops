# 版本敏感点清单：每个命令到底依赖哪些字段

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/gh-json-fields.md`

## 为什么要有这张表

`gh` 的 `--json` 字段集是**跟着版本走**的：同一行 `gh pr list --json newField`
在旧版本会报 `Unknown JSON field`，在新版本可能又悄悄改名。而 REST 的 JSON 字段名
是 GitHub 的公开契约，几乎不会变。

所以本技能的取舍是：

- **读数据** → 一律 `gh api <REST路径> --jq '<表达式>'`，字段名写成表里这样；
- **写动作** → 用 gh 的高层子命令（`release create`/`upload --clobber`/`pr merge`），
  因为它们的参数比手拼 REST 请求体安全；
- **`--jq` 不是外部 jq**：gh 内置 jq 引擎，不需要 `apt install jq`。这一点是本技能
  「零额外依赖」成立的前提。

升级 gh 或改脚本时，**只改这张表**，别在脚本里散着改。

## 0. 传参：`-f` 与 `-F` 不是同义词

| 写法 | 语义 | 适用 |
|---|---|---|
| `-f key=value` | 一律按**字符串**发送 | 文本、路径、分支名、`state=closed` |
| `-F key=value` | 按字面量推断类型：`true`/`false` → 布尔，数字 → 整数，`@file` → 文件内容 | 布尔（`force=true`）、数字（`per_page=100`） |
| `--input -` | 从 stdin 灌整个 JSON | 很长或带换行的文本（几十 KB 以上）、嵌套结构 |

反例（2026-11-22 实测）：`api -X PATCH …/git/refs/heads/x -f sha=… -f force=true` 返回
`422 For 'properties/force', "true" is not a boolean`；同一请求把 `force` 换成
`-F force=true` 即通过。这类 422 容易被误读成权限或参数名问题。

## 1. 仓库（ghadm.sh）

| 用途 | api 路径 | 用到的字段 |
|---|---|---|
| 仓库详情 | `repos/{owner}/{repo}` | `full_name` `visibility` `default_branch` `size` `pushed_at` `open_issues_count` `html_url` |
| 我的仓库列表 | `user/repos?per_page=N&sort=pushed` | `full_name` `visibility` `size` `pushed_at` |
| 改描述/可见性 | `PATCH repos/{owner}/{repo}` | 请求体 `description` `private` |
| 改 topics | `PUT repos/{owner}/{repo}/topics` | 请求体 `{"names":[...]}`（**整体替换**语义） |
| 删仓库 | `DELETE repos/{owner}/{repo}` | — |
| 建仓库 | `POST user/repos` | 请求体 `name` `private` `has_issues` `has_wiki` |
| 仓库是否存在 | `repos/{owner}/{repo}` | 只看退出码（404 → rc≠0） |

## 2. PR（ghadm.sh）

| 用途 | api 路径 | 用到的字段 |
|---|---|---|
| 列表 | `repos/{owner}/{repo}/pulls?state=&per_page=` | `number` `state` `head.ref` `base.ref` `title` |
| 详情 | `repos/{owner}/{repo}/pulls/{n}` | `number` `state` `merged` `mergeable` `head.ref` `base.ref` `title` `user.login` `html_url` |
| 合并 | `gh pr merge {n} -R <slug> --merge\|--squash\|--rebase` | — |
| 关闭 | `PATCH repos/…/pulls/{n}` | 请求体 `state=closed` |
| 评论 | `POST repos/…/issues/{n}/comments` | 请求体 `body`（**PR 的评论走 issues 端点**） |
| 创建 | `gh pr create --title --body --base --head` | 输出即 PR URL |

### 2.1 路径与 ref 编码

`repos/{owner}/{repo}/commits/{ref}` 里，`commits/` 之后的剩余路径段整体当作 ref，
所以分支名里的 `/` 直接写，不必自己 URL 编码。
下例 `$A` = 本技能的 `scripts/ghadm.sh`；`{owner}/{repo}` 是占位，替换成真实值再跑：

```sh
sh "$A" api /repos/{owner}/{repo}/commits/release/1.85 --jq .sha     # 200
sh "$A" api /repos/{owner}/{repo}/commits/release%2F1.85 --jq .sha   # 200，同一个 sha
```

实测 2026-11-22：`microsoft/vscode` 的 `release/1.85`，两条请求均 200 且 sha 相同；
ref 后面还跟段时（如 `…/commits/release/1.85/status`）同样不必编码。
其他路由（`compare/{base}...{head}`、`git/ref/{ref}`）未验证，别顺势扩大。

## 3. Issue（ghadm.sh）

| 用途 | api 路径 | 用到的字段 |
|---|---|---|
| 列表 | `repos/…/issues?state=&per_page=` | `number` `state` `title`；**必须排除** `pull_request != null`（PR 也在 issues 列表里） |
| 关闭 | `PATCH repos/…/issues/{n}` | 请求体 `state=closed` |
| 评论 | `POST repos/…/issues/{n}/comments` | 请求体 `body` |
| 创建 | `POST repos/…/issues` | 请求体 `title` `body`（走 `-f`，由 gh 编码）；`labels` 另走一次 `PUT repos/…/issues/{n}/labels`，用 `-f 'labels[]=x'` |

**实测注意**：`PUT /issues/{n}/labels` 对**不存在**的标签会**自动新建**并挂上
（实测：传 `no-such-label-xyz` 后，该标签出现在 `GET /repos/{o}/{r}/labels` 里，接口仍返回 200）。
也就是说标签名拼错不会报错，只会静默多出一个标签——所以脚本不做白名单校验，
但用完记得去网页或用 `api -X DELETE repos/…/labels/<name>` 清掉。

## 4. Actions（ghadm.sh）

| 用途 | api 路径 | 用到的字段 |
|---|---|---|
| 运行列表 | `repos/…/actions/runs?per_page=` | `workflow_runs[].id` `status` `conclusion` `name` `head_branch` |
| 单次运行 | `repos/…/actions/runs/{id}` | `id` `status` `conclusion` `name` `head_branch` `event` `html_url` |
| 触发 | `gh workflow run <file> -R <slug> --ref <br>` | — |
| 日志 | `gh run view <id> -R <slug> --log > file` | 重定向到文件，不回显（日志可能几十 MB） |

## 5. Release（ghrepo.sh）

| 用途 | 命令 | 说明 |
|---|---|---|
| 建 Release | `gh release create <tag> -R <slug> --title --notes-file --target` | `--target` 只在 tag 不存在时生效 |
| 上传资产 | `gh release upload <tag> <file> -R <slug> --clobber` | `--clobber` = 同名覆盖，本技能的核心改进 |
| 改元信息 | `gh release edit <tag> -R <slug> --title --notes-file` | — |
| 判断是否存在 | `gh release view <tag> -R <slug>` | 只看退出码 |
| 读资产列表 | `repos/…/releases/tags/{tag}` | `assets[].name` `size` `browser_download_url` |
| 读 Release URL | 同上 | `html_url` |

## 6. Gist（ghadm.sh）

| 用途 | 命令 | 说明 |
|---|---|---|
| 创建 | `gh gist create <file...> --desc` | 输出 gist URL。**默认就是 secret**，没有 `--secret` 这个 flag；要公开才加 `--public` |
| 列表 | `gists?per_page=` | `id` `public` `description` `files`（对象，键是文件名） |
| 详情 | `gists/{id}` | `id` `public` `description` `files` `html_url` |
| 取内容 | `gists/{id}` 的 `files[].raw_url` | raw URL 是临时签名地址，用 curl 下载 |
| 删除 | `gh gist delete <id>` | 本技能外层再加复述闸门 |

## 7. 已被本技能抛弃的写法（别改回去）

| 抛弃 | 原因 |
|---|---|
| `json_str()`（用 sed 抠 JSON 字符串） | 只能取平坦的单层字段，遇到嵌套/数组就废；已有 gh 内置 jq |
| `curl` + 手拼 `Authorization` 头做写操作 | 令牌必须手写进请求头，容易在调试输出里泄漏；gh 统一管理 |
| `gh xxx --json` 读字段 | 字段集随版本变，跨设备就飘 |
| `--jq '.a.b'` 取数组整体 | 数组要 `.[]` 展开成 TSV，否则一次只能拿一行 |
| 外部 `jq` | 多一层 apt 依赖，而 gh 自带 |

## 8. 自检一条命令

```sh
sh ghadm.sh api rate_limit --jq '.rate | "LIMIT=\(.limit) REMAIN=\(.remaining)"'
```

能打出 `LIMIT=5000`（带令牌）说明：gh 可执行、令牌有效、jq 引擎可用、出网正常。
四项一次验证完，比逐个试更快。