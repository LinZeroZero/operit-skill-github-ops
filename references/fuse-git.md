# FUSE 上的 git：为什么 add 会 "No such file or directory"，以及两条解法

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/fuse-git.md`

## 1. 环境事实（实测）

| 项 | 实测值 |
|---|---|
| Ubuntu 侧 | proot，aarch64，Ubuntu noble，git 2.43.0（`apt install git` 后） |
| `/storage/emulated/0`（`/sdcard`） | `fuseblk` —— Android 的 FUSE 模拟存储 |
| `/root`（proot 内家目录） | `f2fs` —— 真实 Android 数据分区 |
| proot 启动方式 | 带 link2symlink（从产物文件名 `.l2s.tmp_obj_*` 反推） |

## 2. 三个可复现现象

### 现象 A：`/sdcard` 内建仓，add 直接失败

```sh
mkdir -p /sdcard/t && cd /sdcard/t
git init -q -b main && echo hi > a.txt && git add a.txt
# error: unable to write file .git/objects/45/b983be36...: No such file or directory
# fatal: adding files failed
```

误导点：报错路径看起来不存在，其实 `ls .git/objects/45` 是好的，`touch .git/objects/45/x` 也成功。
所以**不要去修权限、不要去重建目录**，那不是原因。

### 现象 B：外置 git-dir（放在 `/root`，f2fs），add 成功但满屏 garbage

```sh
git init -q --bare -b main /root/repos/x.git
G="git --git-dir=/root/repos/x.git --work-tree=/sdcard/your-project"
$G add -A .
# 成功，但每个对象残留两份临时文件：
#   objects/fa/.l2s.tmp_obj_EZJTUX0001
#   objects/fa/.l2s.tmp_obj_EZJTUX0001.0001
# git count-objects -v  →  count: 21790   garbage: 43580
```

`.l2s.` = **link2symlink**（proot 用来把 `link()` 模拟成「复制 + symlink」的组件）。
它去找临时文件时目标已被改名，于是清理失败，每个对象留两个垃圾文件。

### 现象 C：同一条 FUSE 路径，手工 `mv` 成功、`ln` 失败

```sh
echo x > ab/tmp1 && mv ab/tmp1 ab/final1   # 成功
echo y > ab/tmp2 && ln ab/tmp2 ab/final2   # ln: failed to access 'ab/tmp2': No such file or directory
```

说明：FUSE 上的 **rename 是可用的，link 不可用**。git 默认对象落盘走
`core.createObject` 的 link 优先策略，于是踩在唯一不可用的那一个 syscall 上。

## 3. 解法一（推荐）：`core.createObject rename`

```sh
cd /sdcard/your-project
git init -b main
git config core.createObject rename    # 关键一行
git config core.fileMode false         # FUSE 权限位不可信，否则满屏 mode 变更
git add -A .                           # 实测 exit 0，对象正常落盘、无 garbage
```

实测结论：设了 `rename` 后，FUSE 上 `git add` / `git commit` 全部正常，`git fsck` 无异常，
且不再产生 `.l2s.tmp_obj_*` 垃圾文件。

注意 `core.createObject` 的合法值是 `rename` 与 `link`；写 `files` 会报
`fatal: invalid mode for object creation: files`（网上老文章里的 `files` 是过时值）。

## 4. 解法二：`.git` 放 ext4，work-tree 指向 `/sdcard`

适用于两种情况：目录树特别大（FUSE 上 index 读写慢），或目标是只读介质、`.git` 无法写。

```sh
git init -q --bare -b main /root/repos/项目.git
G="git --git-dir=/root/repos/项目.git --work-tree=/sdcard/your-project"
$G config core.bare false
$G config core.worktree /sdcard/your-project
$G config core.fileMode false
$G add -A .
$G commit -m "..."
```

代价：
- 项目目录里**没有 `.git`**，之后每条命令都要带 `--git-dir/--work-tree`（本技能的 `ghrepo.sh` 全部用
  `git -C "$DIR"` 写，所以两种布局都能直接跑）；
- 现象 B 里那种 `.l2s` 垃圾仍会产生（f2fs 上能完成），用 `git gc --prune=now` 或删 `objects/*/.l2s.*` 清理；
- 想恢复成常规布局：把 `.git` 挪回项目目录即可（`mv /root/repos/项目.git 项目/.git`）。

## 5. 自检清单

```sh
stat -f -c %T "$DIR"                  # 只看一眼是什么文件系统（ghrepo.sh check 会打 FS=）
git -C "$DIR" config core.createObject # 期望 rename（init 无条件写入，与文件系统类型无关）
git -C "$DIR" count-objects -v | grep garbage   # 期望 0 或很小
git -C "$DIR" fsck --no-progress      # 期望只报 unborn branch 之类 notice
```

`ghrepo.sh doctor <DIR>` 已把这几项打包成一行一项。

## 6. 结论一句话

**只要仓库在 `/sdcard` 上，`git config core.createObject rename` 是必备项，不是优化项。**

## 7. 实测基线（同一批：2.3 万文件 / 230 MB，Operit + aarch64 + git 2.43）

| 布局 | `add -A .` | `commit` | 残留 garbage |
|---|---|---|---|
| `.git` 在 `/sdcard` + `createObject=rename`（解法一） | 8 分 49 秒 | 1 分 24 秒 | 0 |
| `.git` 在 `/root`（f2fs）、work-tree 在 `/sdcard`（解法二） | 约 2 分钟 | — | 每对象 2 个 `.l2s` |

换算经验：

- 解法一在 FUSE 上大约 **每分钟 2500 个对象**；2 万文件级别「能接受，一次性等 10 分钟」；
- 上到 5 万文件 / 1 GB 以上，或需要反复提交时，直接用解法二，省下的时间值得那点不直观；
- 小仓库（几百个文件）两种解法都是秒级，优先解法一（项目内 `.git`，日常 `git status` 直接能用）。