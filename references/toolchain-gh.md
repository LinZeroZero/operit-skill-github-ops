# gh 运行环境（工具链）

绝对路径：`/sdcard/Download/Operit/skills/GitHub运维/references/toolchain-gh.md`

## 1. 结论先行

| 问题 | 答案 |
|---|---|
| 用什么 | GitHub 官方 CLI 的 **linux_arm64 静态包**（不是 apt 源里的那版） |
| 装哪 | `/root/tools/gh/bin/gh`（proot 内可执行） |
| 备份在哪 | `技能目录/vendor/gh_2.103.3_linux_arm64.tar.gz`（`/sdcard` 上，重装不丢） |
| 怎么装 | `sh ghenv.sh install`（离线解压，不联网） |
| 怎么恢复 | 重装 proot 后再跑一次 `install`，一条命令 |
| 怎么用令牌 | `export GH_TOKEN=ghp_xxx`，不写 `~/.config/gh/hosts.yml` |

## 2. 为什么不用 apt

Ubuntu 24 源里的 `gh` 版本通常落后好几条 minor，而本技能依赖两件事：
`--jq` 的表达式行为、`gh release upload --clobber` 的覆盖语义。版本过低会得到
「命令存在但参数不认识」这种最难的错误。

更关键的是**恢复成本**：proot 一旦重装（换机、清数据、重置环境），apt 装的包全没，
而且要先把 apt 源改成国内镜像才能 `apt update`。静态包没有这个问题——
tar.gz 就放在技能目录里，重装后 `sh ghenv.sh install` 解压即可，全程不联网。

## 3. 安装的实现细节

`ghenv.sh install` 做这几件事，顺序不能变：

1. **架构校验**：`uname -m` 必须是 `aarch64`/`arm64`。装错架构会得到「能执行但一跑就崩」
   的假成功，比直接报错更难查。
2. **复用判断**：已存在可用 gh 且版本达标时不重复解压（`REUSED=yes`）；`--force` 强制重装。
3. **包校验**：对表里已知的包核 sha256（见 §5），不匹配直接拒绝——半截下载的包解出来是
   一堆乱码错误，比一句「校验失败」费时得多。
4. **暂存解压**：解到 `/root/tools/gh.new.<pid>`，**全程不动**现有安装。
5. **验证暂存副本**：`bin/gh --version` 拿不到版本号就报错（这是「跑不起来」的唯一可靠信号）。
6. **原子替换**：上面全过了，才 `rm -rf /root/tools/gh` 并 `mv` 到位——安装器绝不能把自己
   弄成「没有 gh」的状态。只清这一个目录，**绝不删别的路径**（proot 里误删 `/root` 等于重装环境）。
7. **版本白名单**：主版本 ≥2 且（主版本 >2 或 次版本 ≥45），否则明确报错而不是让后续
   `--json`/`--jq` 飘。允许 3.x 是有意的：新主版本只会更新，不会更旧。

## 4. 探测顺序（ghlib.sh: gh_bin）

```
$GH_BIN（显式指定） → PATH 里的 gh → /root/tools/gh/bin/gh
```

第三项是本技能的关键设计：只要装到固定位置，**所有脚本自动能找到它**，
不需要用户改 `PATH`、也不需要每个 shell session 重新 export。

## 5. 离线包从哪来

官方发布页：`https://github.com/cli/cli/releases`

```sh
# 校验方式（本机已核对过：sha256 与官方 checksums.txt 一致）
sha256sum gh_2.103.3_linux_arm64.tar.gz
# ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
```

升级步骤（要换版本时）：

1. 下载新的 `gh_<ver>_linux_arm64.tar.gz` 与 `gh_<ver>_checksums.txt`；
2. 核对 sha256（不核就等于没校验）；
3. 放进 `技能目录/vendor/`（可保留多份，`find_tarball` 取**版本号最高**的一份；没有 `sort -V` 的环境按字典序并给警告）；
4. `sh ghenv.sh install --force`；
5. `sh ghenv.sh check` 确认 `GH_VERSION_OK=yes`。

## 6. 令牌注入

`gh` 的令牌优先级：`GH_TOKEN` > `GITHUB_TOKEN` > `~/.config/gh/hosts.yml`。
本技能只用前两个（`ghlib.sh` 里做了 `GH_TOKEN ||= GITHUB_TOKEN` 的归一），
理由：

- `hosts.yml` 明文落盘，且 proot 重装即丢（属于「一换机就要重新配」的东西）；
- 环境变量不落盘、不进 `ps`（对比命令行参数）、不进 shell 历史；
- 一次 `export` 后，`git` 与 `gh` 两条链路共用同一个令牌。

**不要**跑 `gh auth login`：它是交互式的，会让数字/浏览器 OAuth 流程，
在手机终端里既难走完，又会顺手写坏 `hosts.yml`。

## 7. 常见故障

### `install` 报「装好的 gh 跑不起来」
先手动跑一次 `/root/tools/gh/bin/gh --version` 看真实报错：
- `Exec format error` → 包架构不对（下成 x86_64 了）；
- 无输出且立即退出 → 极罕见，说明该二进制在当前 proot 内核/ABI 下无法运行。
  此时不要硬撑，改用 apt 版本（`apt-get install -y gh`）并把 `GH_MIN_MINOR` 的判断放宽。

### `check` 报 `GH_VERSION_OK=no`
版本低于 2.45，或根本不是 gh。重新 `install --force`。

### 下载慢或失败
`/sdcard` 上留一份 tar.gz 就够了。也可直接放到 `/sdcard/Download/`——
`find_tarball` 会去那里找，不需要重新下载。

### 空间占用
静态二进制约 38 MB，压缩包 13 MB。想省空间可以删 `/sdcard/Download/` 下的包，
只保留 `vendor/` 里那份。