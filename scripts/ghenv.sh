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
#   退出码 0=环境可用  2=gh 缺失/版本不符/包缺失/校验失败  3=令牌无效
#   check 输出（每行 KEY=VALUE，**键唯一**）：ARCH GH_BIN GH_VERSION GH_VERSION_OK
#                                              GIT TOKEN LOGIN API [HINT]

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

# 离线包优先级：显式 GH_TARBALL > 技能自带 vendor/ > 下载目录手工放置的。
# 同一目录有多份时取版本号最高的一份：字典序会把 2.9 排在 2.10 之后（选错版本），
# 所以先试 sort -V；没有 sort -V 的环境退化成字典序，并明确告知。
find_tarball() {
  if [ -n "${GH_TARBALL:-}" ]; then
    if [ -f "$GH_TARBALL" ]; then printf '%s' "$GH_TARBALL"; return 0; fi
    warn "GH_TARBALL 指向的文件不存在: $GH_TARBALL（继续按默认位置找）"
  fi
  for _ft_dir in "$SKILL_DIR/vendor" /sdcard/Download; do
    [ -d "$_ft_dir" ] || continue
    _ft_list=$(ls -1 "$_ft_dir"/gh_*_linux_arm64.tar.gz 2>/dev/null)
    [ -n "$_ft_list" ] || continue
    _ft_pick=$(printf '%s\n' "$_ft_list" | sort -V 2>/dev/null | tail -1)
    if [ -z "$_ft_pick" ]; then
      _ft_pick=$(printf '%s\n' "$_ft_list" | sort | tail -1)
      warn "sort -V 不可用，按字典序选了 $_ft_pick（多版本共存时请手动指定 GH_TARBALL）"
    fi
    printf '%s' "$_ft_pick"
    return 0
  done
  return 1
}

# 已知离线包的 sha256（与 references/toolchain-gh.md §5 一致）。
# 只对表里有的包做严格校验；没有 sha256sum 的环境降级为警告。
# 为什么值得校验：半截下载的 tar.gz 解出来是一堆乱码错误，比一句「校验失败」费时得多。
verify_tarball() {
  _vt_f=$1
  case "$(basename "$_vt_f")" in
    gh_2.103.3_linux_arm64.tar.gz)
      _vt_want=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63 ;;
    *)
      warn "没有该包的已知 sha256，跳过完整性校验：$(basename "$_vt_f")"
      return 0 ;;
  esac
  if ! command -v sha256sum >/dev/null 2>&1; then
    warn "没有 sha256sum，跳过完整性校验"
    return 0
  fi
  _vt_got=$(sha256sum "$_vt_f" 2>/dev/null | awk '{print $1}')
  [ "$_vt_got" = "$_vt_want" ] || die2 "离线包校验失败：期望 $_vt_want，实际 ${_vt_got:-无}（重新下载，见 toolchain-gh.md §5）"
  kv SHA256 ok
}

cmd_version() {
  need_gh
  gh_version
}

cmd_check() {
  _ck_arch=$(uname -m)
  kv ARCH "$_ck_arch"

  if _ck_b=$(gh_bin); then
    GH=$_ck_b
    export GH
    kv GH_BIN "$_ck_b"
    kv GH_VERSION "$(gh_version)"
    if gh_version_ok; then
      kv GH_VERSION_OK yes
      _ck_ver=yes
    else
      kv GH_VERSION_OK "no（需要 2.${GH_MIN_MINOR}+，字段集才可信）"
      _ck_ver=no
    fi
  else
    kv GH_BIN absent
    kv GH_VERSION absent
    kv GH_VERSION_OK no
    _ck_ver=no
  fi

  kv GIT "$(git --version 2>/dev/null || echo absent)"

  # 令牌与登录名各只输出一次。KEY=VALUE 契约要求键唯一，
  # 早期版本在「有令牌但接口失败」时会把 LOGIN= 打两遍（一次 -、一次真值），
  # 解析方（awk -F= / grep ^LOGIN=）会取到哪个完全看运气。
  if [ -z "$GH_TOKEN" ]; then
    kv TOKEN absent
    kv LOGIN -
    kv API "skipped（缺令牌）"
    _ck_tok=no
  elif [ "$_ck_ver" = no ]; then
    kv TOKEN present
    kv LOGIN -
    kv API "skipped（缺 gh）"
    _ck_tok=yes
  else
    kv TOKEN present
    # 只有 gh 在、令牌也在，才值得打一次真实接口：这一步同时验证令牌与出网
    if _ck_l=$(gh_login); then
      kv LOGIN "$_ck_l"
      kv API ok
      _ck_tok=yes
    else
      kv LOGIN -
      kv API fail
      kv HINT "令牌或出网有问题：先看 references/auth.md §4 的 401/403 对照，再看 troubleshoot.md"
      _ck_tok=no
    fi
  fi

  # 分档退出：缺 gh 是环境问题（2），令牌不对是凭据问题（3），别混成一个码
  [ "$_ck_ver" = yes ] || die2 "环境不可用：先跑 sh ghenv.sh install"
  [ "$_ck_tok" = yes ] || die3 "令牌不可用：export GH_TOKEN=ghp_xxx（classic 令牌勾 repo）"
  echo "OK"
}

cmd_install() {
  _in_force=no
  for _in_a in "$@"; do
    case "$_in_a" in
      --force) _in_force=yes ;;
      *) die1 "未知参数: $_in_a" ;;
    esac
  done

  # 架构先对齐：包里只有 arm64，装错架构会得到「可执行但一跑就崩」的假成功
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die2 "本技能只带 linux_arm64 静态包，当前架构 $(uname -m)；请改用 apt 或自备包" ;;
  esac

  if [ "$_in_force" = no ]; then
    if _in_b=$(gh_bin) && GH=$_in_b && export GH && gh_version_ok; then
      kv REUSED "yes（gh $(gh_version) 已可用；要重装加 --force）"
      kv GH_BIN "$_in_b"
      echo "OK"
      return 0
    fi
  fi

  _in_tar=$(find_tarball) || die2 "找不到离线包：期望 $SKILL_DIR/vendor/gh_*_linux_arm64.tar.gz 或 /sdcard/Download/ 下同名文件"
  kv TARBALL "$_in_tar"
  verify_tarball "$_in_tar"

  # 原子替换：先解到同目录的临时位置并验证能跑，再 mv 到位。
  # 为什么不能 rm -rf 原目录再解压：包损坏/断电会留下「没有 gh」的状态，
  # 而这时连本脚本自己都要靠重装来救——安装器把自己弄坏是最糟的失败模式。
  mkdir -p "$(dirname "$GH_INSTALL_DIR")" 2>/dev/null
  _in_new="$GH_INSTALL_DIR.new.$$"
  rm -rf "$_in_new"
  mkdir -p "$_in_new" || die2 "无法创建 $_in_new（proot 内需要 root）"
  if ! tar -xzf "$_in_tar" -C "$_in_new" --strip-components=1; then
    rm -rf "$_in_new"
    die2 "解压失败：$_in_tar（包可能不完整，见 references/toolchain-gh.md §5）"
  fi
  chmod 755 "$_in_new/bin/gh" 2>/dev/null
  if [ ! -x "$_in_new/bin/gh" ]; then
    rm -rf "$_in_new"
    die2 "解压后没找到 bin/gh，包结构不符"
  fi
  _in_v=$("$_in_new/bin/gh" --version 2>/dev/null | awk 'NR==1{print $3}')
  if [ -z "$_in_v" ]; then
    rm -rf "$_in_new"
    die2 "装好的 gh 跑不起来：手动跑 $_in_new/bin/gh --version 看真实报错（Exec format error = 包架构不对）"
  fi

  # 到这里才动原安装。只清固定安装目录：proot 里误删 /root 等于重装环境。
  rm -rf "$GH_INSTALL_DIR"
  mv "$_in_new" "$GH_INSTALL_DIR" || die2 "无法把 $_in_new 改名为 $GH_INSTALL_DIR"

  GH=$GH_INSTALL_DIR/bin/gh
  export GH
  kv GH_BIN "$GH"
  kv GH_VERSION "$_in_v"
  gh_version_ok || die2 "版本 $_in_v 低于 2.${GH_MIN_MINOR}，--json 字段集可能不符"
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