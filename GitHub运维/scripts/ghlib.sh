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
# 兼容性：只用 POSIX sh 语法，外部命令只挑 coreutils 与 toybox 共有的那部分。
#   手机上的 sh 可能是 proot 的 dash，也可能是 Android 自带的 mksh，
#   所以这里不许出现 local / [[ ]] / ${v//a/b} / 数组 / pipefail。
#
# 对外契约（改之前先想清谁依赖它）：
#   退出码  0=成功  1=用法错误或参数/预条件冲突  2=环境错误（无 gh / 目录不存在 / 不是仓库）
#           3=令牌缺失或无效  4=网络或远端错误  5=破坏性操作未通过闸门
#   输出    单条结果 KEY=VALUE（键唯一）；列表一律 TSV（字段用真 tab），首行 '# 表头'
#
# 为什么令牌只走环境变量：命令行参数会进 shell 历史与 ps 输出，环境变量不会。
# 为什么绝不写 ~/.config/gh/hosts.yml：proot 重装会丢，且那是明文落盘。

# ---- 常量与运行环境 ---------------------------------------------------------

# gh 从 2.45 起 --json / --jq / release upload --clobber 行为稳定；低于它字段集不可信。
# 不锁死补丁号（2.x 内字段集向后兼容），也不把主版本钉成 =2（3.0 只会更新不会更旧）。
GH_MIN_MAJOR=2
GH_MIN_MINOR=45

# 令牌不落盘：只接受 GH_TOKEN / GITHUB_TOKEN，且不做任何回写
: "${GH_TOKEN:=${GITHUB_TOKEN:-}}"
export GH_TOKEN

# 全链路强制非交互。手机终端里 gh 一旦想「开编辑器 / 开分页器 / 问一句 yes」，
# 表现就是「卡住不动」——那是最难自查的故障，所以这里把口子一次性全堵掉：
#   *_PAGER/PAGER        → 永不分页
#   GH_PROMPT_DISABLED   → 需要交互确认时直接报错，而不是等一个永远不来的输入
#   GIT_TERMINAL_PROMPT  → git 不许问密码（问就是没有，直接失败）
#   GIT_EDITOR/EDITOR    → 谁想开编辑器都只会拿到「什么也不做」的 true
export GH_PAGER=cat PAGER=cat GIT_PAGER=cat
export GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 NO_COLOR=1
export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true EDITOR=true

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

kv() { printf '%s=%s\n' "$1" "$2"; }

# 分段标题：只为人读（check / doctor 这种多段输出用），机器解析只看 KEY=VALUE 行
sec() { printf '%s\n' "-- $* --"; }

# 列表首行表头。字段之间用真 tab，与数据行保持一致——用空格的话，
# 把输出粘到表格/awk 里会整体错列，而这类错列看起来像「脚本算错了」。
# 多参数形式，内部零 fork（只用 printf）。
tsv_header() {
  _th_first=yes
  printf '# '
  for _th_f in "$@"; do
    if [ "$_th_first" = yes ]; then _th_first=no; else printf '\t'; fi
    printf '%s' "$_th_f"
  done
  printf '\n'
}

# ---- gh 探测 ----------------------------------------------------------------

# 探测顺序有讲究：显式 GH_BIN > PATH 里的 gh > 技能自带的离线安装位置。
# 最后一项让「重装 proot 后 ghenv.sh install」装到固定位置即可被全部脚本找到。
gh_bin() {
  if [ -n "${GH_BIN:-}" ]; then
    if [ -x "$GH_BIN" ]; then printf '%s' "$GH_BIN"; return 0; fi
    # 显式指定却不可执行属于「配置错」，不是「没装」：要说出来，不能静默降级
    warn "GH_BIN 指向的文件不可执行: $GH_BIN（继续按默认顺序探测）"
  fi
  if command -v gh >/dev/null 2>&1; then command -v gh; return 0; fi
  if [ -x /root/tools/gh/bin/gh ]; then printf '%s' /root/tools/gh/bin/gh; return 0; fi
  return 1
}

need_gh() {
  GH=$(gh_bin) || die2 "没找到 gh。先跑：sh \"$SKILL_DIR/scripts/ghenv.sh\" install（离线解压 vendor 里的包）"
  export GH
}

gh_version() { "$GH" --version 2>/dev/null | awk 'NR==1{print $3}'; }

# 版本闸门：主版本 >= 2 且（主版本 > 2 或 次版本 >= 45）。
# 为什么不校验补丁号：2.x 内字段集向后兼容，卡补丁号只会自找麻烦；
# 为什么必须校验：旧 gh 上 --jq / release upload --clobber 是「命令存在但参数不认」，
# 属于最难查的一类错误，宁可在这里直接判死。
gh_version_ok() {
  _vo=$(gh_version)
  [ -n "$_vo" ] || return 1
  _vo_maj=${_vo%%.*}
  _vo_rest=${_vo#*.}
  _vo_min=${_vo_rest%%.*}
  # 非数字（例如把别的东西改名成 gh）会让 [ 报错并返回非 0，正好当作「不达标」
  [ "$_vo_maj" -ge "$GH_MIN_MAJOR" ] 2>/dev/null || return 1
  [ "$_vo_maj" -gt "$GH_MIN_MAJOR" ] 2>/dev/null && return 0
  [ "$_vo_min" -ge "$GH_MIN_MINOR" ] 2>/dev/null
}

# ---- 调用的统一入口 ---------------------------------------------------------

# 把 gh 的 stderr 翻译成本技能退出码。
# gh 所有失败都只返回 1，不解析文案就分不清「参数冲突」「令牌过期」「仓库不存在」
# 和「今天网络不好」，而这四种对调用者的处置完全不同。
#
# 分类顺序有讲究：参数/预条件冲突必须排在鉴权前面。
# 因为 422 的文案常常同时带 "Validation Failed" 与资源名，先命中鉴权分支
# 就会被误报成「换令牌」，让人白折腾半小时去重建 PAT。
classify_rc() {
  case "$1" in
    *"unknown flag"*|*"unknown command"*|*"--yes required"*|*"required flag"*|*"accepts "*" arg"*)
      printf '1' ;;
    *"HTTP 422"*|*"Validation Failed"*|*"already_exists"*|*"already exists"*|*"Unprocessable Entity"*)
      printf '1' ;;
    *"HTTP 401"*|*"HTTP 403"*|*"Bad credentials"*|*"not authenticated"*|\
    *"authentication"*|*"Resource not accessible"*|*"Must have admin"*|*"GH_TOKEN"*)
      printf '3' ;;
    *)
      # 404 / 5xx / DNS / TLS / 超时全落这里：对调用者都是「先看网络与仓库名」
      printf '4' ;;
  esac
}

# ghrun <gh 子命令...>：成功时把 stdout 原样吐给调用者，失败时按分类退出。
# 之所以缓存到临时文件而不是管道：需要在成功/失败两条路上都完整读到输出
# （管道会让 rc 只是最后一环的 rc，sh 里没有 pipefail 可用）。
ghrun() {
  _gr_o=$(mktemp) || die2 "mktemp 失败"
  _gr_e=$(mktemp) || die2 "mktemp 失败"
  "$GH" "$@" >"$_gr_o" 2>"$_gr_e"
  _gr_rc=$?
  if [ "$_gr_rc" -ne 0 ]; then
    _gr_msg=$( { cat "$_gr_e"; head -c 300 "$_gr_o"; } 2>/dev/null | tr -d '\r' )
    rm -f "$_gr_o" "$_gr_e"
    _gr_code=$(classify_rc "$_gr_msg")
    err "$(printf '%s' "$_gr_msg" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ')"
    case "$_gr_code" in
      1) err "判断：参数或预条件冲突（退出码 1），处置见 references/troubleshoot.md" ;;
      3) err "判断：令牌无效或权限不足（退出码 3），处置见 references/auth.md" ;;
      *) err "判断：网络或远端错误（退出码 4），处置见 references/troubleshoot.md" ;;
    esac
    exit "$_gr_code"
  fi
  cat "$_gr_o"
  rm -f "$_gr_o" "$_gr_e"
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

# 打印版：直接输出登录名，给 ghenv.sh check 之类「要一个值」的场景用。
gh_login() {
  _lg=$("$GH" api user --jq .login 2>/dev/null)
  [ -n "$_lg" ] || return 1
  printf '%s' "$_lg"
}

# 变量版：结果放全局 GH_LOGIN，成功返回 0。
# 为什么不写成 GH_LOGIN=$(gh_login)：$( ) 是子 shell，里面做的任何赋值都回不到父进程，
# 于是「缓存」形同虚设，一个流程里会反复打 /user 接口（每次都是一次跨境往返）。
gh_login_resolve() {
  if [ -n "${GH_LOGIN:-}" ]; then return 0; fi
  GH_LOGIN=$("$GH" api user --jq .login 2>/dev/null)
  if [ -z "$GH_LOGIN" ]; then
    GH_LOGIN=
    return 1
  fi
  return 0
}

# ---- 仓库定位 ---------------------------------------------------------------

# 把 origin 归一成 owner/repo。支持三种写法，全程只用参数展开（零 fork、无 sed 版本差异）：
#   https://host/owner/repo(.git)     ssh://git@host/owner/repo     git@host:owner/repo(.git)
# 顺序：去 scheme → 去 userinfo（含可能残留的令牌）→ 处理 scp 的 host: → 去 host 段
# → 去末尾斜杠 → 去 .git
slug_of() {
  _sg=$1
  case "$_sg" in
    *://*) _sg=${_sg#*://} ;;                  # 去 scheme
  esac
  case "$_sg" in
    *@*) _sg=${_sg#*@} ;;                      # 去 userinfo（git@ / x-access-token:tok@）
  esac
  case "$_sg" in
    *:*)                                       # scp 写法 host:owner/repo
      case "${_sg#*:}" in
        [0-9]*) : ;;                           # 冒号后是数字 → 这是 host:port，不动
        *) _sg=${_sg#*:} ;;
      esac
      ;;
  esac
  case "$_sg" in
    */*/*) _sg=${_sg#*/} ;;                    # 还剩 host/owner/repo 时去掉 host 段
  esac
  _sg=${_sg%/}
  _sg=${_sg%.git}
  printf '%s' "$_sg"
}

need_dir()  { [ -d "$1" ] || die2 "目录不存在: $1"; }
need_git()  { command -v git >/dev/null 2>&1 || die2 "没装 git：apt-get install -y --no-install-recommends git"; }
need_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || die2 "不是 git 仓库（先跑 ghrepo.sh init）: $1"; }
need_curl() { command -v curl >/dev/null 2>&1; }

# 归一到「绝对真实路径」，两处用途都不能省：
#   1. /sdcard 与 /storage/emulated/0 是同一处的两种写法，而 find -path、git safe.directory
#      都是字符串比对：写法不一致就静默失效（.git 没被 -prune 掉、目录被判 dubious ownership）；
#   2. 去掉末尾斜杠，否则 "$DIR/.git" 会拼成 "/p//.git"，永远匹配不上。
norm_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }

# 从某个目录的 origin 反推 owner/repo；失败只返回非 0，由调用方决定报什么错。
repo_slug_here() {
  _rs_o=$(git -C "${1:-.}" remote get-url origin 2>/dev/null) || return 1
  [ -n "$_rs_o" ] || return 1
  slug_of "$_rs_o"
}

# ---- 破坏性闸门 -------------------------------------------------------------

# 为什么单独要「复述目标」而不是只给一个 --yes：
# --yes 是习惯性动作，手一抖就执行；复述 owner/repo 或 gist id 必须真的看清目标。
# 复述不一致时直接退出 5，连一个网络请求都不发。
#
# 参数形态：第二个位置参数**就是**复述本身，没有 --confirm 这类开关。
# （早期版本的报错文案写成了「需要 --confirm "x"」，照做的用户会第二次仍然失败，
#   而失败原因看起来像「明明写对了」—— 纯文案 bug，已修。）
gate_confirm() {
  _gc_target=$1
  _gc_given=$2
  # 目标为空时必须拒绝：否则 `delete "" ""` 会因为两者都空而「复述一致」，删到空 id 上
  [ -n "$_gc_target" ] || die1 "拒绝执行：闸门目标为空（缺少 id 或仓库名），不发起任何请求"
  if [ -z "$_gc_given" ]; then
    die5 "拒绝执行：这是破坏性操作（目标：$_gc_target）。请把目标名原样再写一遍作为第二个参数"
  fi
  [ "$_gc_target" = "$_gc_given" ] || die5 "拒绝执行：第二个参数写的是「$_gc_given」，实际目标是「$_gc_target」"
}