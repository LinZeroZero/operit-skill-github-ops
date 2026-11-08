#!/bin/sh
# ghlib.sh — 「GitHub 运维」技能的公共库：被 source，不单独执行
#
# 定位：把三件事收在一处，避免 ghrepo.sh / ghadm.sh / ghenv.sh 各写一份——
#   1. 环境探测：gh 二进制在哪、版本够不够、令牌在不在
#   2. 调用规则：统一走 ghrun()，把 gh 的「一律返回 1」翻译成本技能的退出码
#   3. 契约与闸门：输出格式（KEY=VALUE / TSV）、破坏性操作必须先复述目标
#
# 位置：/sdcard/Download/Operit/skills/GitHub运维/scripts/ghlib.sh
# 用法：调用方先设 PROG，再 `. "$(dirname "$0")/ghlib.sh"`
#       （/sdcard 是 noexec，所以只能 `sh <脚本>`，source 同理由 sh 负责解释）
#
# 对外契约（改之前先想清谁依赖它）：
#   退出码  0=成功  1=用法错误  2=环境错误（无 gh / 目录不存在 / 不是仓库）
#           3=令牌缺失或无效  4=网络或远端错误  5=破坏性操作未通过闸门
#   输出    单条结果 KEY=VALUE；列表一律 TSV，首行 '# 表头'
#
# 为什么令牌只走环境变量：命令行参数会进 shell 历史与 ps 输出，环境变量不会。
# 为什么绝不写 ~/.config/gh/hosts.yml：proot 重装会丢，且那是明文落盘。

# ---- 常量与运行环境 ---------------------------------------------------------

# gh 从 2.45 起 --json / --jq / release upload --clobber 行为稳定；低于它字段集不可信
GH_MIN_MAJOR=2
GH_MIN_MINOR=45

# 令牌不落盘：只接受 GH_TOKEN / GITHUB_TOKEN，且不做任何回写
: "${GH_TOKEN:=${GITHUB_TOKEN:-}}"
export GH_TOKEN

# gh 默认会调 $PAGER 分页、会为版本更新提示多打一次网络请求，手机终端里都只添乱
export GH_PAGER=cat
export GH_NO_UPDATE_NOTIFIER=1
export NO_COLOR=1

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)
SKILL_DIR=${SKILL_DIR:-$(dirname "$SELF_DIR")}

# ---- 输出与退出 -------------------------------------------------------------

err()  { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die1() { err "$*"; exit 1; }
die2() { err "$*"; exit 2; }
die3() { err "$*"; exit 3; }
die4() { err "$*"; exit 4; }
die5() { err "$*"; exit 5; }

kv()   { printf '%s=%s\n' "$1" "$2"; }
tsv_header() { printf '# %s\n' "$*"; }

# ---- gh 探测 ----------------------------------------------------------------

# 探测顺序有讲究：显式 GH_BIN > PATH 里的 gh > 技能自带的离线安装位置。
# 最后一项让「重装 proot 后 ghenv.sh install」装到固定位置即可被全部脚本找到。
gh_bin() {
  if [ -n "${GH_BIN:-}" ] && [ -x "${GH_BIN}" ]; then printf '%s' "$GH_BIN"; return 0; fi
  if command -v gh >/dev/null 2>&1; then command -v gh; return 0; fi
  if [ -x /root/tools/gh/bin/gh ]; then printf '%s' /root/tools/gh/bin/gh; return 0; fi
  return 1
}

need_gh() {
  GH=$(gh_bin) || die2 "没找到 gh。先跑：sh \"$SKILL_DIR/scripts/ghenv.sh\" install（离线解压 vendor 里的包）"
  export GH
}

gh_version() { "$GH" --version 2>/dev/null | awk 'NR==1{print $3}'; }

# 版本白名单：只校验「主版本=2 且次版本>=45」。
# 不锁死补丁号，因为字段集在 2.x 内是向后兼容的；不校验就可能在旧 gh 上静默解析失败。
gh_version_ok() {
  _v=$(gh_version)
  [ -n "$_v" ] || return 1
  _maj=${_v%%.*}
  _rest=${_v#*.}
  _min=${_rest%%.*}
  [ "$_maj" = "$GH_MIN_MAJOR" ] && [ "$_min" -ge "$GH_MIN_MINOR" ] 2>/dev/null
}

# ---- 调用的统一入口 ---------------------------------------------------------

# 把 gh 的 stderr 翻译成本技能退出码。
# gh 所有失败都只返回 1，不解析文案就分不清「令牌过期」和「今天网络不好」，
# 而这两者对调用者的处置完全不同（换令牌 vs 等一会儿重试）。
classify_rc() {
  case "$1" in
    *"unknown flag"*|*"unknown command"*|*"--yes required"*|*"required flag"*|*"accepts "*" arg"*)
      printf '1' ;;
    *"HTTP 401"*|*"HTTP 403"*|*"Bad credentials"*|*"not authenticated"*|\
    *"authentication"*|*"Resource not accessible"*|*"Must have admin"*|*"GH_TOKEN"*)
      printf '3' ;;
    *"HTTP 404"*|*"Not Found"*|*"no such host"*|*"Could not resolve"*)
      printf '4' ;;
    *"dial tcp"*|*"timeout"*|*"i/o timeout"*|*"TLS handshake"*|*"connection reset"*|*"HTTP 5"*)
      printf '4' ;;
    *)
      printf '4' ;;
  esac
}

# ghrun <gh 子命令...>：成功时把 stdout 原样吐给调用者，失败时按分类退出。
# 之所以缓存到临时文件而不是管道：需要在成功/失败两条路上都完整读到输出
# （管道会让 rc 只是最后一环的 rc，sh 里没有 pipefail 可用）。
ghrun() {
  _o=$(mktemp) || die2 "mktemp 失败"
  _e=$(mktemp) || die2 "mktemp 失败"
  "$GH" "$@" >"$_o" 2>"$_e"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    _msg=$( { cat "$_e"; head -c 300 "$_o"; } 2>/dev/null | tr -d '\r' )
    rm -f "$_o" "$_e"
    _code=$(classify_rc "$_msg")
    err "$(printf '%s' "$_msg" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ')"
    [ "$_code" = "3" ] && err "判断：令牌无效或权限不足（401/403）"
    [ "$_code" = "4" ] && err "判断：网络或远端错误，处置见 references/troubleshoot.md"
    exit "$_code"
  fi
  cat "$_o"
  rm -f "$_o" "$_e"
}

# 需要「成功就用、失败也不退出」的探测（例如判断仓库是否已存在）走这个。
# 返回 gh 的原始退出码，stdout 为输出，stderr 丢弃——调用方只看 rc。
gh_try() {
  "$GH" "$@" 2>/dev/null
}

# ---- 令牌与身份 -------------------------------------------------------------

need_token() {
  [ -n "$GH_TOKEN" ] || die3 "缺少令牌：export GH_TOKEN=ghp_xxx（classic 令牌勾 repo 权限）"
}

# 取当前令牌对应的登录名。缓存是因为一次运行里常常要连查好几个接口。
gh_login() {
  if [ -n "${_GH_LOGIN:-}" ]; then printf '%s' "$_GH_LOGIN"; return 0; fi
  _l=$("$GH" api user --jq .login 2>/dev/null)
  [ -n "$_l" ] || return 1
  _GH_LOGIN=$_l
  printf '%s' "$_l"
}

# ---- 仓库定位 ---------------------------------------------------------------

# 从 origin 解析 owner/repo，支持 https 与 git@ 两种写法，并去掉末尾 .git
slug_of() {
  printf '%s' "$1" | sed -e 's#^https://github.com/##' -e 's#^git@github.com:##' \
    -e 's#/$##' -e 's#\.git$##'
}

need_dir() { [ -d "$1" ] || die2 "目录不存在: $1"; }
need_git() { command -v git >/dev/null 2>&1 || die2 "没装 git：apt-get install -y --no-install-recommends git"; }
need_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || die2 "不是 git 仓库（先跑 ghrepo.sh init）: $1"; }

# 从当前目录向上找 origin；找不到就报错，让调用者显式传 --repo
repo_slug_here() {
  _o=$(git -C "${1:-.}" remote get-url origin 2>/dev/null) || return 1
  [ -n "$_o" ] || return 1
  slug_of "$_o"
}

# ---- 破坏性闸门 -------------------------------------------------------------

# 为什么单独要「复述目标」而不是只给一个 --yes：
# --yes 是习惯性动作，手一抖就执行；复述 owner/repo 或 gist id 必须真的看清目标。
# 复述不一致时直接退出 5，连一个网络请求都不发。
gate_confirm() {
  _target=$1
  _given=$2
  # 目标为空时必须拒绝：否则 `delete "" ""` 会因为两者都空而「复述一致」，删到空 id 上
  [ -n "$_target" ] || die1 "拒绝执行：闸门目标为空（缺少 id 或仓库名），不发起任何请求"
  if [ -z "$_given" ]; then
    die5 "拒绝执行：这是破坏性操作（目标 $_target），需要 --confirm \"$_target\" 复述目标"
  fi
  [ "$_target" = "$_given" ] || die5 "拒绝执行：--confirm 写的是「$_given」，实际目标是「$_target」"
}