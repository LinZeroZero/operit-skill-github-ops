# 发布前脱敏（仓库转 public / 分享技能）

定位：SKILL.md 与 references 里的示例路径，长期带着写它那天的工作区名。
仓库一旦转 public，等于把个人目录结构公开。这份文件是「发布前 5 分钟」流程。

判断标准只有一条：**这段字符串能否定位到「这个人」或「这台设备」**。
能定位就改，不能定位就留——不是消灭所有路径字符串。

## 1. 什么算隐私，什么不算

| 内容 | 算不算 | 处理 |
|---|---|---|
| `/storage/emulated/0`、`/sdcard`、`/data/data/<包名>` | 不算 | 所有 Android 设备都一样，是挂载点不是标识 |
| `/storage/emulated/0/<工作区>/<项目>` 里的 `<工作区>` | **算** | 换成 `/sdcard/your-project` |
| 技能自身安装路径 `/sdcard/Download/Operit/skills/<技能名>/` | 不算，且**必须写实** | 占位化会让 `read_file` 打不开脚本 |
| 内网 IP、设备序列号、IMEI、Android ID | **算** | 用 `192.168.1.10`、`<device-id>` |
| 真实邮箱、手机号 | **算** | 用 `you@example.com` |
| 令牌、私钥 | **算** | 一律 `<token>` 或 `$GH_TOKEN`，绝不写真实值 |
| 项目名、包名（如 `<公司>.<app>`） | **算** | 用 `com.example.app` |

## 2. 三种统一占位写法

```
/sdcard/your-project        项目根
owner/repo                  仓库
<token> / $GH_TOKEN         令牌
```

## 3. 扫描（复制即用）

```sh
R=/sdcard/Download/Operit/skills/<技能名>

# 1) 绝对路径：看有没有「挂载点 + 你自己的工作区名」这种组合
grep -rInE '/storage/emulated/0/[A-Za-z0-9_-]+/|/sdcard/[A-Za-z0-9_-]+/' "$R" --exclude-dir=.git

# 2) 设备与身份标识
grep -rIn -iE 'serial[ _-]?(no|number)|imei|android_id' "$R" --exclude-dir=.git

# 3) IP（127.0.0.1 可留，局域网/公网 IP 要改）
grep -rIhoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$R" --exclude-dir=.git | sort | uniq -c

# 4) 邮箱：全部列出来逐个判断（example.com / users.noreply.github.com 可留）
grep -rIhoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$R" --exclude-dir=.git | sort -u

# 5) 密钥与令牌
grep -rIn -E 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9]{10,}|BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' "$R" --exclude-dir=.git
```

`--exclude-dir=.git` 是必须的：否则会把历史提交里的旧值一起扫出来，噪音淹没真结果。
不要把 `--exclude='*.tar.gz'` 之类写进模板，换一个技能就得重写；真遇到二进制再临时加。

## 4. 替换：别信 sed 的返回码

实测教训：用中文长串做精确匹配的批量替换，13 对里静默漏了 2 对，
而 sed 全程返回 0、`sh -n` 也过——**工具说成功不等于改对了**。

```sh
D=/sdcard/Download/Operit/skills
git -C "$D" status --short                   # 1) 必须干净，后面才好用 diff 复核

sed -i -e 's#/storage/emulated/0/<工作区>/<项目>#/sdcard/your-project#g' \
       -e 's#/sdcard/<工作区>/<项目>#/storage/emulated/0/your-project#g'  文件...

git -C "$D" diff -U0 | grep -E '^[-+]' | grep -vE '^[-+]{2}'   # 2) 逐条回读，数量要对得上
grep -rIn '/<工作区>/' "$R" --exclude-dir=.git                  # 3) 残留必须为空
```

`git diff -U0` 只打改动行，比读全文快，还能一眼数出「说有 9 处、实际是不是 9 对」。
顺序有讲究：先改长模式（含子目录），再改短模式，否则短模式先命中会把长模式的锚点拆掉。

## 5. 教学价值不能跟着一起删

典型场景：文档演示「同一路径有两种写法，都要登记」。

坏的改法（两行变成重复废话，读者看不出为什么要写两条）：

```sh
git config --global --add safe.directory /sdcard/your-project
git config --global --add safe.directory /sdcard/your-project   # ← 重复了，说明失效
```

正确做法是保留写法差异，只换掉工作区名：

```sh
git config --global --add safe.directory /sdcard/your-project
git config --global --add safe.directory /storage/emulated/0/your-project
```

同理，讲挂载机制的表格行（`/storage/emulated/0（/sdcard）| fuseblk`）、
讲两种写法差异的脚本注释，都该原样保留——删了原理就说不清了。

## 6. 验证：不带令牌从远端抓回来

本地干净不等于远端干净（可能忘了 push，或 push 前又改了回来）。
用匿名 clone 验证，一次同时证明两件事：内容干净、仓库确实 public。

```sh
rm -rf /root/vr
git clone -q --depth 1 https://github.com/<owner>/<repo>.git /root/vr && echo CLONE_OK
grep -rIn '/<工作区>/' /root/vr; echo "(空 = 干净)"
git -C /root/vr log --oneline -1        # 确认抓到的是最新提交
rm -rf /root/vr
```

`CLONE_OK` 之外还该看 `log`：如果短提交号不是刚推的那个，说明远端没更新，别急着报完成。

## 7. 藏不住的：仓库地址本身

public 仓库的 URL 就是 `github.com/<用户名>/<仓库>`，README 里的 clone 命令必然带用户名。
这不属于「能清掉」的范围——连用户名都不想露的话，只能建组织仓库或换小号，
不是脱敏能解决的，也就不要在文档里假装解决了。

## 8. 实测记录（可复用的对照）

2026-11 对 `<owner>/operit-skills` 做过一次完整脱敏：

- 命中 10 处，判定 **7 处要改、3 处保留**（挂载机制表格、脚本注释、工具链说明）；
- 其中 1 处按第 5 节的做法保留了「两种写法」的教学对照，没有退化成重复行；
- 匿名 clone 复查：残留零命中，`your-project` 出现 8 次（第 9 处改成了 `/sdcard/t`，符合预期）。

结论：先把「该留什么」列出来再动手，比直接扫「该删什么」更省事——
后者很容易顺手删掉解释性内容。
