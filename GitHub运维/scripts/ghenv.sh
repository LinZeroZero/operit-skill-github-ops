#!/bin/sh
# ghenv.sh — gh 运行环境：体检、离线安装、重装后恢复
#
# 定位：本技能其余脚本都假设「gh 可用且版本够新」。这个脚本就是那个假设的守门人：
#   check    只读体检，先跑它，任何一项不对就先修环境再干活
#   install  从 vendor/ 里的官方 arm64 静态包离线解压到 /root/tools/gh（不联网、不 apt）
#   version  只打版本号，给别的脚本或人快速取用
#
# 位置：/sdcard/Download/Operit/skills/GitHub运维/scripts/ghenv.sh
# 调用：sh ghenv.sh check        （/sdcard 是 noexec，必须用 sh 前缀）
#
# 为什么不走 apt：proot 换机/重装后 apt 源要先修镜像才能用，而 gh 官方 arm64 包是
# 纯静态 Go 二进制，解压即用；把 tar.gz 留在技能目录里，重装 proot 也只丢 /root/tools，
# 一条 install 就恢复。apt 源里那版通常落后好几条 minor，--json 字段集还可能对不上。
#
# 对外契约：
#   退出码 0=环境可用  2=gh 缺失/版本不符/包缺失  3=令牌无效
#   check 输出（每行 KEY=VALUE）：ARCH GH_BIN GH_VERSION GH_VERSION_OK GIT TOKEN LOGIN API

set +e

PROG=ghenv.sh
. "$(dirname "$0")/ghlib.sh"

usage() {
  cat <<'EOF'
用法: sh ghenv.sh <子命令>

  check          只读体检：gh 路径/版本/架构、git、令牌、登录名、API 连通性
  install        把 vendor/ 里的官方 arm64 静态包解压到 /root/tools/gh（离线，不联网）
                 [--force]  已有可用 gh 也强制重装（升级/修复用）
  version        只输出 gh 版本号

退出码: 0 环境可用 / 2 gh 缺失或版本不符或包缺失 / 3 令牌无效
环境变量: GH_BIN（指定 gh 路径） GH_TOKEN（令牌） GH_TARBALL（指定离线包路径）
EOF
}

GH_INSTALL_DIR=/root/tools/gh

# 离线包优先级：显式 GH_TARBALL > 技能自带 vendor/ > 下载目录手工放置的
find_tarball() {
  for _c in "${GH_TARBALL:-}" "$SKILL_DIR"/vendor/gh_*_linux_arm64.tar.gz \
            /sdcard/Download/gh_*_linux_arm64.tar.gz; do
    if [ -n "$_c" ] && [ -f "$_c" ]; then printf '%s' "$_c"; return 0; fi
  done
  return 1
}

cmd_version() {
  need_gh
  gh_version
}

cmd_check() {
  _arch=$(uname -m)
  kv ARCH "$_arch"

  if _b=$(gh_bin); then
    GH=$_b
    export GH
    kv GH_BIN "$_b"
    kv GH_VERSION "$(gh_version)"
    if gh_version_ok; then
      kv GH_VERSION_OK yes
      _ver_ok=yes
    else
      kv GH_VERSION_OK "no（需要 2.${GH_MIN_MINOR}+，字段集才可信）"
      _ver_ok=no
    fi
  else
    kv GH_BIN "absent"
    kv GH_VERSION "absent"
    kv GH_VERSION_OK no
    _ver_ok=no
  fi

  kv GIT "$(git --version 2>/dev/null || echo absent)"

  if [ -z "$GH_TOKEN" ]; then
    kv TOKEN absent
    kv LOGIN "-"
    _tok_ok=no
  else
    kv TOKEN present
    _tok_ok=yes
  fi

  # 只有 gh 在、令牌也在，才值得打一次真实接口：这一步同时验证令牌与出网
  if [ "$_ver_ok" = yes ] && [ "$_tok_ok" = yes ]; then
    if _l=$(gh_login); then
      kv LOGIN "$_l"
      kv API ok
    else
      kv LOGIN "-"
      kv API fail
      _tok_ok=no
    fi
  else
    # LOGIN 在上一段已经打过（无令牌时就是 -），这里只补 API 状态，避免同一行出现两次
    kv API "skipped（缺 gh 或缺令牌）"
  fi

  # 分档退出：缺 gh 是环境问题（2），令牌不对是凭据问题（3），别混成一个码
  [ "$_ver_ok" = yes ] || die2 "环境不可用：先跑 sh ghenv.sh install"
  [ "$_tok_ok" = yes ] || die3 "令牌不可用：export GH_TOKEN=ghp_xxx（classic 令牌勾 repo）"
  echo "OK"
}

cmd_install() {
  _force=no
  for _a in "$@"; do
    case "$_a" in
      --force) _force=yes ;;
      *) die1 "未知参数: $_a" ;;
    esac
  done

  # 架构先对齐：包里只有 arm64，装错架构会得到「可执行但一跑就崩」的假成功
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die2 "本技能只带 linux_arm64 静态包，当前架构 $(uname -m)；请改用 apt 或自备包" ;;
  esac

  if [ "$_force" = no ]; then
    if _b=$(gh_bin) && GH=$_b && export GH && gh_version_ok; then
      kv REUSED "yes（gh $(gh_version) 已可用；要重装加 --force）"
      kv GH_BIN "$_b"
      echo "OK"
      return 0
    fi
  fi

  _tar=$(find_tarball) || die2 "找不到离线包：期望 $SKILL_DIR/vendor/gh_*_linux_arm64.tar.gz 或 /sdcard/Download/ 下同名文件"
  kv TARBALL "$_tar"

  # 只清固定安装目录。这里不能动别的路径：proot 里误删 /root 就等于重装环境。
  rm -rf "$GH_INSTALL_DIR"
  mkdir -p "$GH_INSTALL_DIR" || die2 "无法创建 $GH_INSTALL_DIR（proot 内需要 root）"
  tar -xzf "$_tar" -C "$GH_INSTALL_DIR" --strip-components=1 || die2 "解压失败：$_tar"
  chmod 755 "$GH_INSTALL_DIR/bin/gh" 2>/dev/null

  [ -x "$GH_INSTALL_DIR/bin/gh" ] || die2 "解压后没找到 bin/gh，包结构不符"
  GH=$GH_INSTALL_DIR/bin/gh
  export GH
  _v=$(gh_version)
  [ -n "$_v" ] || die2 "装好的 gh 跑不起来（ptrace/架构问题？）"
  kv GH_BIN "$GH"
  kv GH_VERSION "$_v"
  gh_version_ok || die2 "版本 $_v 低于 2.${GH_MIN_MINOR}，--json 字段集可能不符"
  echo "OK"
}

CMD=$1
[ $# -gt 0 ] && shift

case "$CMD" in
  check)   cmd_check ;;
  install) cmd_install "$@" ;;
  version) cmd_version ;;
  help|-h|--help) usage; exit 0 ;;
  "") usage; exit 1 ;;
  *) err "未知子命令: $CMD"; usage; exit 1 ;;
esac
