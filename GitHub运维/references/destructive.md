# 破坏性操作：哪些事不可逆，以及本技能怎么拦

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/destructive.md`

## 1. 一句话结论

**能撤回的叫操作，不能撤回的叫事故。**本技能只对后者设闸门：
删仓库、删 Gist、以及任何会被 `api -X DELETE` 触发的动作。

闸门不是「你点了个 yes」，而是「你得把目标名再打一遍」——因为 `--yes` 是肌肉记忆，
而准确复述 `owner/repo` 或 gist id 必须真的看一眼。

## 2. 闸门的实现

```sh
# ghlib.sh
gate_confirm() {
  _target=$1     # 实际目标
  _given=$2      # 调用者复述
  [ -z "$_given" ] && die5 "拒绝执行：这是破坏性操作（目标 $_target），需要 --confirm \"$_target\""
  [ "$_target" = "$_given" ] || die5 "拒绝执行：--confirm 写的是「$_given」，实际目标是「$_target」"
}
```

行为：

- 复述缺失 → 退出码 **5**，不发任何请求；
- 复述不一致 → 退出码 **5**，不发任何请求；
- 一致 → 才真正调用 API。

退出码 5 是独立的，不与「用法错误(1)」混淆：脚本被自动化调用时，看到 5 就知道
「是我不肯删」，而不是「参数写错了」。

## 3. 操作矩阵

| 操作 | 命令 | 可逆性 | 闸门 |
|---|---|---|---|
| 删仓库 | `ghadm.sh repo-delete <slug> <slug>` | 网页可恢复一段时间，但**名下引用、Release、Actions 记录全没** | ✅ 需复述 |
| 删 Gist | `ghadm.sh gist-delete <id> <id>` | **不可逆**，没有回收站；public gist 可能已被搜索引擎收录 | ✅ 需复述 |
| 任意 DELETE | `ghadm.sh api -X DELETE <path>` | 看端点，多数不可逆 | ⚠️ **不拦**（见下） |
| 合并 PR | `ghadm.sh pr-merge` | 可 revert，但历史已写入 | ❌ 不拦 |
| 关闭 PR/Issue | `ghadm.sh pr-close` / `issue-close` | 可重开 | ❌ 不拦 |
| 覆盖 Release 资产 | `ghrepo.sh republish` | 同名覆盖，旧链接仍有效 | ❌ 不拦（设计如此） |
| 强推 / 改历史 | — | 可能永久丢别人的提交 | ❌ **本技能不提供** |

### 关于 `api -X DELETE` 不拦的原因

它是逃生舱：真需要的端点（删 release 资产、删分支、删 deploy key）不在本技能封装范围内。
给它加闸门只会让人去网页点，反而更危险——网页点删除**没有复述确认**。
但请遵守一条：**调用前先 `api <同一路径>` 看一眼对象对不对**，再删。

## 4. 权限前提：删除仓库要单独的 `delete_repo`

这是最容易白折腾半小时的一点：

- classic 令牌勾 `repo` → 能建仓、能推、能发版，**但删仓库返回 403**；
- 要删仓库，必须**额外勾 `delete_repo`**；
- fine-grained 令牌需要 `Administration: Read and write`。

所以 `repo-delete` 报 403 时，先去看令牌，而不是怀疑脚本。

## 5. 被删之后

| 对象 | 恢复可能 |
|---|---|
| 仓库 | 网页 Settings → Deleted repositories 里可恢复（GitHub 保留一段时间），但 Issues/PR/Actions 记录不完整回来 |
| Release 资产 | 不可恢复，只能重新上传 |
| Gist | **不可恢复** |
| 分支 | 本技能不删分支；`git push --delete` 后可用 reflog + 强推恢复，前提是本地还有 |
| 提交 | 本技能不改写历史，所以不存在「提交被改写」的情况 |

## 6. 调用方（AI 或人）的正确流程

1. 先**只读确认目标**：`sh ghadm.sh repo-view <slug>`，把 `FULL_NAME` / `SIZE_KB` / `PUSHED_AT` 摆出来；
2. 把目标名念一遍，问一句「是要删这个吗」；
3. 得到明确同意后，再带上复述参数执行；
4. 执行后核对输出 `DELETED=<slug>`。

**禁止**：在用户只说了「清理一下」的时候自行推断目标并删除。
不确定就不删——删错了没有撤销按钮，而多做一次确认只花十秒。
