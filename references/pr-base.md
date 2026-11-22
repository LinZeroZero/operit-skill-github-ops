# 目标分支确认与 base 分叉重放

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/pr-base.md`
最后验证：2026-11-22（4.1–4.6 走通一次，实际路径是「情况 B + pushurl 分流」；情况 A 与 4.3 的 get-url 自检未单独实跑）

配套：`SKILL.md` 规则 6、`scripts/ghadm.sh`（`pr-create` 的 base 已改为必填）、`scripts/ghrepo.sh`。

## 1. 这篇解决什么

PR 的目标分支不是 `default_branch`：前者回答「这次改动合到哪」，后者只回答「clone 默认落哪个分支」。
选错之后有两类后果：

1. 被要求改 base，白走一轮沟通；
2. 目标分支与当前 base 已分叉时，「只点 Edit base」会让三点差异把上游别人的改动算进来 ——
   PR 页面看起来正常，实际混进了不属于这次改动的文件。

实测（2026-11-22）：某仓库 `default_branch=main`，而 `dev` 与 `main` 已分叉
（`dev` 缺 `main` 上 10 个提交；8 个 `strings.xml` 两边内容不同，同一份 `ChatScreenHeader.kt` 相同）。

## 2. 确认目标分支

按优先级取值：

1. `CONTRIBUTING.md`、`.github/pull_request_template.md`、`docs/` 下的贡献说明；
2. 没有文档 → 数最近一批 PR 的 base 分布（实际执行的标准就在数据里）：

```sh
A="/sdcard/Download/Operit/skills/GitHub运维/scripts/ghadm.sh"
sh "$A" api '/repos/OWNER/REPO/pulls?state=all&per_page=20' --jq '.[] | .base.ref' \
  | sort | uniq -c | sort -rn
```

`state=all` 默认按创建时间倒序，含已关闭与已合并的 PR，样本足够判断多数派。
分布混杂时按多数派走，少数派当「例外」处理，不要当成反例。

## 3. 先判断「能不能只改 base」

```sh
sh "$A" api '/repos/OWNER/REPO/compare/MAIN...TARGET' --jq '{ahead:.ahead_by,behind:.behind_by}'
```

- `behind_by=0` → 目标分支已包含原 base 的全部历史，只改 base 即可；
- `behind_by>0` → 两边分叉，走第 4 节重放；
- 逐文件判断可以比 blob：`contents/<path>?ref=<branch> --jq .sha`，相同即内容一致。

## 4. 重放流程（实测命令）

变量约定：`$W` = 本地工作目录，`$TB` = 目标分支名，`$FB` = PR 头分支名，`$UP` = 上游 `owner/repo`，`$FORK` = 自己的 fork，`$S` = 技能 `scripts` 目录，`$A` = `$S/ghadm.sh`（4.1 里赋值，本节其余命令复用）。

### 4.1 只拉提交图 + 稀疏检出

远端要分清两件事：**fetch 取到有该分支的一方，push 必须落到自己的 fork**。
`ghrepo.sh push` 执行的是 `git push origin HEAD:refs/heads/$BR`，只认 `origin`，
所以两种情况最后都要把 `origin` 的 **pushurl** 指向 fork（`git push` 优先用 pushurl，fetch 仍走 origin）。

两种情况都要先放令牌（4.3 的 push 用它；只在这一处出现，用完 unset）：

```sh
export GH_TOKEN=...                      # 只在这一处出现，用完 unset
S="/sdcard/Download/Operit/skills/GitHub运维/scripts"
A="$S/ghadm.sh"
```

情况 A：fork 上已有目标分支 —— 直接 clone fork。

```sh
git clone --filter=tree:0 --no-checkout --single-branch --branch "$TB" \
  "https://github.com/$FORK.git" "$W/repo"
```

情况 B：fork 上没有目标分支 —— clone 上游，让缺的树按需从上游取。

```sh
git clone --filter=tree:0 --no-checkout --single-branch --branch "$TB" \
  "https://github.com/$UP.git" "$W/repo"
```

两种情况的后半段相同：

```sh
cd "$W/repo"
git remote set-url --push origin "https://github.com/$FORK.git"   # 4.3 的 push 落点
git remote -v                                                     # 必须看到 push 指向 fork
git sparse-checkout init --cone
git sparse-checkout set <改动目录1> <改动目录2> ...
git checkout -B "$FB"
```

实测（情况 B）：593 MB 的仓库，`.git` 只有 2.1 MB；稀疏检出 9 个目录后工作区 16 MB / 3440 文件。
`--filter=tree:0` 让树按需取，`--single-branch` 避免拉全部分支；
公开仓库可以匿名 clone，不需要令牌。

克隆到的 `$TB` 必须先与上游 `$TB` 对齐 —— 情况 A 的 fork 可能落后一代，
这时 4.2 的父提交检查照样通过，但 PR 会把上游的改动算成「删除」：

```sh
git rev-parse "$TB"                                    # 本地拿到的顶端
sh "$A" api /repos/$UP/commits/$TB --jq .sha           # 上游的顶端
```

两者不相等就先对齐：`git fetch "https://github.com/$UP.git" "$TB" && git reset --hard FETCH_HEAD`。

这一步必须放在**放改动之前**（4.1 末尾）：此时工作区里还没有你的文件，`reset --hard` 不会丢东西。
若你已经放过改动，先备份再 reset，回读后逐文件比对 hash（同 `SKILL.md` 规则 5）。

### 4.2 放改动并提交（走 ghrepo.sh）

```sh
sh "$S/ghrepo.sh" check  "$W/repo"        # 只读体检：体积/大文件/连通性/令牌
sh "$S/ghrepo.sh" stage  "$W/repo"
sh "$S/ghrepo.sh" commit "$W/repo" "<提交说明>"
```

提交后立刻核对父提交与改动量，父提交必须等于 `$TB` 的顶端：

```sh
git --no-pager log -1 --format='%h parent=%p'
git --no-pager diff --stat HEAD^ HEAD | tail -3
```

### 4.3 先推临时分支（避开 force push）

`ghrepo.sh push` 固定执行 `push origin HEAD:refs/heads/$BR`，不带 `--force`；
远端同名分支历史不同就会 `non-fast-forward`。改推一个新分支名（快进，合法）：

```sh
git checkout -B "rebase-$TB"
git remote get-url --push origin          # 先确认落点是 fork，不是上游
sh "$S/ghrepo.sh" push "$W/repo"
```

若上面那行输出的是上游地址，说明 4.1 的 `set-url --push` 没生效，别继续往下走 ——
往上游推会因无写权限失败，或者推成功了但 4.4 改的 fork ref 指向不存在的提交（422）。

实测：只补目标分支那一个提交的差异对象，7 秒完成（`PUSHED=<sha>`）。

情况 B 下这条推送会顺带打出一条 `WARN: 远端跟踪引用 origin/<分支> 未更新`：
`ghrepo.sh push` 结束时会从 `origin` 的 fetchurl（= 上游）回填跟踪引用，
而上游没有这个临时分支。它不影响远端内容，属于情况 B 的预期输出。

### 4.4 用 API 把 PR 头分支指过去

```sh
sh "$A" api -X PATCH /repos/$FORK/git/refs/heads/$FB -F sha=<新提交全 sha> -F force=true
sh "$A" api -X DELETE /repos/$FORK/git/refs/heads/rebase-$TB
```

`-F` 不能写成 `-f`：`-f` 传的是字符串，接口会返回
`422 For 'properties/force', "true" is not a boolean`。

### 4.5 改 PR base 并核对三点差异

```sh
sh "$A" api -X PATCH /repos/$UP/pulls/<编号> -f base=$TB
sh "$A" api /repos/$UP/pulls/<编号> \
  --jq '{base:.base.ref,commits:.commits,changed:.changed_files,add:.additions,del:.deletions,ms:.mergeable_state}'
```

判据：`changed_files` 与 `additions/deletions` 必须等于自己的改动清单，`commits` 等于重放后的提交数。
对不上说明 tree 没对齐（常见原因：还有别的文件在两个分支间内容不同，需要一并处理）。

### 4.6 回退

第 4.4 步之前必须先记下远端旧 sha（`sh "$A" api /repos/$FORK/git/refs/heads/$FB --jq .object.sha`）：

```sh
sh "$A" api -X PATCH /repos/$FORK/git/refs/heads/$FB -F sha=<旧 sha> -F force=true
sh "$A" api -X PATCH /repos/$UP/pulls/<编号> -f base=<原 base>
```

## 5. CI 判读

- `pull_request.branches` 决定 CI 是否触发。base 不在列表里时，PR 的 `check-runs=0`，
  容易被误判成「这个仓库没有 CI」。
- 首次贡献者的 workflow run 会停在 `conclusion=action_required`、`jobs` 数为 0，
  要维护者点 Approve and run。这不是失败。
- `mergeable_state` 常见值：`clean`、`blocked`（等 review 或分支保护）、
  `unstable`（checks 未完成或待批准）、`dirty`（冲突）、`unknown`（GitHub 还在算）。

## 6. 边界

- 第 4.4 节的 ref 改写**只允许**用于自己 fork 上的 PR 头分支；不得用于他人分支，
  不得用于任何受保护分支。
- 改写前必须记下旧 sha；改写后立刻核对三点差异，对不上就按 4.6 回退。
- 拿不到旧 sha 就不要执行第 4.4 步。
