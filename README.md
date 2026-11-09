# Operit 技能 · GitHub 运维

在 Android 手机上用 `gh` + `git` 管理 GitHub 的技能包：建仓推送、Release、PR/Issue、Actions、Gist，
并且专门解决 Android 独有的坑（FUSE 存储上 `git add` 报路径不存在、令牌如何不进 `ps`、toybox 与 GNU 命令差异）。

四个脚本：`ghenv`（环境）/ `ghrepo`（推送与发版）/ `ghadm`（仓库·PR·Issue·CI·Gist）/ `ghlib`（公共库）。
令牌只从环境变量 `GH_TOKEN` 读，不写 remote、不写 `~/.git-credentials`、不拼进命令行。

## 安装

装到哪：`/sdcard/Download/Operit/skills/GitHub运维/` —— Operit 的技能目录，放好即被识别。

### 方式一：让 Operit 的 AI 自己装（推荐）

把下面这句话直接发给 Operit 里的 AI：

> 安装技能：GitHub 运维，仓库是 https://github.com/LinZeroZero/operit-skill-github-ops

AI 会去 Release 取包、解开、校验 `SKILL.md` 是否到位。

### 方式二：一行命令（Android 自带 curl + tar，不需要 root）

```sh
curl -fL https://github.com/LinZeroZero/operit-skill-github-ops/releases/latest/download/github-ops.tar.gz \
  | tar -xz -C /sdcard/Download/Operit/skills
```

### 方式三：安装脚本（带回滚、验包、`--check`）

```sh
curl -fL -o /data/local/tmp/ops-install.sh \
  https://raw.githubusercontent.com/LinZeroZero/operit-skill-github-ops/main/install.sh

sh /data/local/tmp/ops-install.sh --check   # 先看现在装的是什么，不下载
sh /data/local/tmp/ops-install.sh           # 安装
```

脚本流程：下载 → `tar -tzf` 验包 → 备份旧版 → 解包 → 校验 `SKILL.md`。
已存在同名目录时**不会直接覆盖**，而是改名为 `GitHub运维.bak.<时间戳>`；确定要硬覆盖就加 `--force`。

也可以指定别处先试装，不影响现有技能：

```sh
sh /data/local/tmp/ops-install.sh /sdcard/tmp/skills
```

### 方式四：git clone（想用 `git pull` 跟进更新）

```sh
git clone --depth 1 https://github.com/LinZeroZero/operit-skill-github-ops.git \
  "/sdcard/Download/Operit/skills/GitHub运维"
```

## 装完验证

```sh
sh "/sdcard/Download/Operit/skills/GitHub运维/scripts/ghenv.sh" check
```

期望看到 `GH_VERSION_OK=yes`、`TOKEN=present`、`API=ok`。
要先有令牌：`export GH_TOKEN=<你的令牌>`，scope 至少 `repo`；需要删仓库再加 `delete_repo`。

`gh` 不用自己装：`vendor/gh_2.103.3_linux_arm64.tar.gz` 就在仓库里，
`sh scripts/ghenv.sh install` 会离线解压到固定位置，全程不联网。

## 目录

| 路径 | 内容 |
|---|---|
| `SKILL.md` | 技能主文件，AI 入口：四条硬规则 + 两条主链路 |
| `scripts/ghenv.sh` | gh 安装、体检、恢复（开工第一步） |
| `scripts/ghrepo.sh` | 建仓、提交、推送、发 Release |
| `scripts/ghadm.sh` | 仓库/PR/Issue/Actions/Gist 管理 |
| `scripts/ghlib.sh` | 公共库（退出码、闸门、探测） |
| `references/fuse-git.md` | FUSE 上 `add` 失败的根因与两条解法 |
| `references/auth.md` | 令牌怎么选、权限最小集、401/403/404 对照 |
| `references/troubleshoot.md` | 症状 → 原因 → 处理（五档） |
| `references/gh-json-fields.md` | 各命令依赖的 JSON 字段（版本敏感点） |
| `references/destructive.md` | 破坏性操作矩阵与闸门规则 |
| `references/sanitize.md` | 仓库转 public 前怎么脱敏 |
| `vendor/` | gh 离线包 |

## 更新

- 方式一/三：重跑 `install.sh`（旧目录自动备份成 `.bak.<时间戳>`）
- 方式四：`git -C "/sdcard/Download/Operit/skills/GitHub运维" pull`

## 卸载

```sh
mv "/sdcard/Download/Operit/skills/GitHub运维" "/sdcard/Download/GitHub运维.bak"
```

不提供 `install.sh --remove`：删目录不可逆，交给使用者自己决定更安全。

## 依赖

| 依赖 | 是否有 | 说明 |
|---|---|---|
| `curl`、`tar`、`gzip` | Android 自带 | `/system/bin`，toybox 0.8.12，装技能零额外依赖 |
| `git` | 需自备 | proot Ubuntu（`apt install git`）或 Termux |
| `gh` | 仓库自带 | `vendor/` 离线包，`ghenv.sh install` 解压；要求 ≥ 2.45 |
| root | 不需要 | 全部操作在 `/sdcard` 与用户目录内 |
