#!/bin/sh
# ghadm.sh — GitHub 日常运维：仓库、PR、Issue、Actions、Gist
#
# 定位：ghrepo.sh 管「把代码推上去并发版」，本脚本管「推完之后的所有事」。
# 之所以和 ghrepo.sh 分开：推送链路是高频操作，必须短到能一次读透；
# 这些管理动作是低频扩展，按需再读，避免把高频脚本撑成一千行。
#
# 位置：/sdcard/Download/Operit/skills/GitHub运维/scripts/ghadm.sh
# 调用：sh ghadm.sh <子命令> ...      （/sdcard 是 noexec）
#
# 对外契约：
#   退出码  0=成功 1=用法 2=环境 3=令牌 4=网络/远端 5=闸门未通过
#   输出    单条结果 KEY=VALUE；列表为 TSV，首行 '# 表头'
#
# 两条实现取舍（改代码前先读）：
#   1. 查询一律走 `gh api` + REST 字段，不用 `gh xxx --json`：
#      REST 字段名是契约，`--json` 的可选字段集随 gh 版本增删，写死会漂。
#      唯一例外是 Gist（它不是仓库子资源，gh gist 子命令比裸 API 更省事）。
#   2. 所有命令必须能非交互跑完：gh 一旦需要编辑正文/选择合并方式就会打开
#      编辑器或 TUI，在手机终端里表现为「卡住不动」，所以标题、正文、合并方式
#      一律由参数给死。

set +e

PROG=ghadm.sh
. "$(dirname "$0")/ghlib.sh"

usage() {
  cat <<'EOF'
用法: sh ghadm.sh <子命令> [参数]

仓库
  repo-view   <owner/repo|.>
  repo-list   [数量]
  repo-edit   <owner/repo|.> <描述|-> <public|private|keep> [topics逗号分隔|-]
  repo-delete <owner/repo> <复述同名 owner/repo>      # 破坏性，需复述
  repo-clone  <owner/repo> [目标目录]

PR
  pr-create   <DIR> <标题> <正文|-> [base分支]        # head 取当前分支
  pr-list     <owner/repo|.> [open|closed|all] [数量]
  pr-view     <owner/repo|.> <编号>
  pr-merge    <owner/repo|.> <编号> [merge|squash|rebase]
  pr-close    <owner/repo|.> <编号>
  pr-comment  <owner/repo|.> <编号> <正文>

Issue
  issue-create  <owner/repo|.> <标题> <正文|-> [标签逗号分隔]
  issue-list    <owner/repo|.> [open|closed|all] [数量]
  issue-close   <owner/repo|.> <编号>
  issue-comment <owner/repo|.> <编号> <正文>

Actions
  ci-list     <owner/repo|.> [数量]
  ci-view     <owner/repo|.> <run-id>
  ci-run      <owner/repo|.> <workflow文件名或ID> [ref分支]
  ci-logs     <owner/repo|.> <run-id> <输出文件>

Gist
  gist-create <描述> <文件...>
  gist-list   [数量]
  gist-view   <gist-id>
  gist-get    <gist-id> <输出文件> [文件名]            # 不给文件名取第一个
  gist-delete <gist-id> <复述同名 gist-id>              # 破坏性，需复述

其它
  api <gh api 的参数...>                                # 透传，兜底任意 REST 调用
  help

退出码: 0 成功 / 1 用法 / 2 环境 / 3 令牌 / 4 网络或远端 / 5 闸门未通过
令牌: export GH_TOKEN=ghp_xxx
EOF
}

# ---- 通用 -------------------------------------------------------------------

# 接受 owner/repo，也接受 . 表示「用当前目录 origin」，省得每次手抄仓库名
resolve_slug() {
  _s=$1
  case "$_s" in
    ""|.) repo_slug_here . || die2 "当前目录没有 origin，请显式给 owner/repo" ;;
    */*)  printf '%s' "$_s" ;;
    *)    die1 "仓库要写成 owner/repo，收到：$_s" ;;
  esac
}

# 正文参数里 - 表示空正文：gh 拿不到正文就会想开编辑器，必须显式给空串
body_arg() {
  if [ "$1" = "-" ]; then printf ''; else printf '%s' "$1"; fi
}

need_num() {
  case "$1" in
    ''|*[!0-9]*) die1 "编号必须是数字，收到：$1" ;;
  esac
}

# gist id 是十六进制串（通常 20~32 位）。校验它是为了拦住「变量没取到就成了空」这种情况：
# 空 id 会被拼成 `gists/`，随后要么 404 要么删到空目标，两者都比直接报错更难查。
need_gist_id() {
  case "$1" in
    ''|*[!0-9a-fA-F]*) die1 "gist id 应是十六进制串，收到：$1" ;;
  esac
  [ ${#1} -ge 8 ] || die1 "gist id 太短，收到：$1"
}

# ---- 仓库 -------------------------------------------------------------------

cmd_repo_view() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG repo-view <owner/repo|.>"
  need_gh; need_token
  SLUG=$(resolve_slug "$1")
  tsv_header "field value"
  ghrun api "repos/$SLUG" \
    --jq '"FULL_NAME=\(.full_name)\nVISIBILITY=\(.visibility)\nDEFAULT_BRANCH=\(.default_branch)\nSIZE_KB=\(.size)\nPUSHED_AT=\(.pushed_at)\nOPEN_ISSUES=\(.open_issues_count)\nURL=\(.html_url)"'
}

cmd_repo_list() {
  LIM=${1:-30}
  need_gh; need_token
  tsv_header "full_name visibility size_kb pushed_at"
  ghrun api "user/repos?per_page=$LIM&sort=pushed" \
    --jq '.[] | "\(.full_name)\t\(.visibility)\t\(.size)\t\(.pushed_at)"'
}

cmd_repo_edit() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG repo-edit <owner/repo|.> <描述|-> <public|private|keep> [topics|-]"
  SLUG=$(resolve_slug "$1"); DESC=$2; VIS=$3; TOPICS=${4:--}
  need_gh; need_token

  # 逐个拼而不是一次性字符串展开：描述里带空格时不会被拆成多个参数
  set -- api -X PATCH "repos/$SLUG"
  [ "$DESC" != "-" ] && set -- "$@" -f "description=$DESC"
  case "$VIS" in
    public)  set -- "$@" -F private=false ;;
    private) set -- "$@" -F private=true ;;
    keep)    ;;
    *)       die1 "可见性只能是 public/private/keep" ;;
  esac
  ghrun "$@" --jq '.full_name' >/dev/null

  if [ "$TOPICS" != "-" ]; then
    # topics 是独立端点，且必须整体覆盖（PATCH /topics 的语义是替换）
    _json=$(printf '%s' "$TOPICS" | awk -F',' '{printf "{\"names\":["; for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]}"}')
    ghrun api -X PUT "repos/$SLUG/topics" --input - <<EOF >/dev/null
$_json
EOF
  fi

  kv REPO "$SLUG"
  kv UPDATED yes
  echo "OK"
}

cmd_repo_delete() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG repo-delete <owner/repo> <复述同名 owner/repo>"
  SLUG=$(resolve_slug "$1")
  gate_confirm "$SLUG" "$2"      # 不一致直接退出 5，不发请求
  need_gh; need_token
  ghrun api -X DELETE "repos/$SLUG" >/dev/null
  kv DELETED "$SLUG"
  echo "OK"
}

cmd_repo_clone() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG repo-clone <owner/repo> [目标目录]"
  SLUG=$(resolve_slug "$1"); DEST=${2:-}
  need_gh; need_token
  if [ -n "$DEST" ]; then
    ghrun repo clone "$SLUG" "$DEST" >/dev/null
    kv CLONED "$DEST"
  else
    ghrun repo clone "$SLUG" >/dev/null
    kv CLONED "$(basename "$SLUG")"
  fi
  echo "OK"
}

# ---- PR ---------------------------------------------------------------------

cmd_pr_create() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG pr-create <DIR> <标题> <正文|-> [base分支]"
  DIR=$1; TITLE=$2; BODY=$(body_arg "$3"); BASE=${4:-main}
  need_dir "$DIR"; need_repo "$DIR"; need_gh; need_token
  HEAD=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)
  [ -n "$HEAD" ] || die2 "拿不到当前分支（detached HEAD）"
  ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -n "$ORIGIN" ] || die2 "还没设 origin"
  SLUG=$(slug_of "$ORIGIN")

  # --title/--body 都显式给：缺任一项 gh 会尝试打开编辑器，在手机终端里等于卡死
  # `|| exit $?` 见 ghlib.sh 的 ghrun 注释：命令替换里的 exit 需要显式转发
  OUT=$(ghrun pr create -R "$SLUG" --head "$HEAD" --base "$BASE" \
    --title "$TITLE" --body "$BODY") || exit $?
  kv PR_URL "$OUT"
  kv PR_NUMBER "$(printf '%s' "$OUT" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -1)"
  kv HEAD "$HEAD"
  kv BASE "$BASE"
  echo "OK"
}

cmd_pr_list() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG pr-list <owner/repo|.> [open|closed|all] [数量]"
  SLUG=$(resolve_slug "$1"); STATE=${2:-open}; LIM=${3:-20}
  need_gh; need_token
  tsv_header "number state head base title"
  ghrun api "repos/$SLUG/pulls?state=$STATE&per_page=$LIM" \
    --jq '.[] | "\(.number)\t\(.state)\t\(.head.ref)\t\(.base.ref)\t\(.title)"'
}

cmd_pr_view() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG pr-view <owner/repo|.> <编号>"
  SLUG=$(resolve_slug "$1"); NUM=$2; need_num "$NUM"
  need_gh; need_token
  ghrun api "repos/$SLUG/pulls/$NUM" \
    --jq '"NUMBER=\(.number)\nSTATE=\(.state)\nMERGED=\(.merged)\nMERGEABLE=\(.mergeable)\nHEAD=\(.head.ref)\nBASE=\(.base.ref)\nTITLE=\(.title)\nAUTHOR=\(.user.login)\nURL=\(.html_url)"'
}

cmd_pr_merge() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG pr-merge <owner/repo|.> <编号> [merge|squash|rebase]"
  SLUG=$(resolve_slug "$1"); NUM=$2; METHOD=${3:-merge}; need_num "$NUM"
  need_gh; need_token
  case "$METHOD" in
    merge|squash|rebase) ;;
    *) die1 "合并方式只能是 merge/squash/rebase" ;;
  esac
  # 不传 --delete-branch：删分支不可逆，留给人在网页上决定
  ghrun pr merge "$NUM" -R "$SLUG" "--$METHOD" >/dev/null
  _m=$("$GH" api "repos/$SLUG/pulls/$NUM" --jq .merged 2>/dev/null)
  kv PR "$NUM"
  kv MERGED "$_m"
  kv METHOD "$METHOD"
  echo "OK"
}

cmd_pr_close() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG pr-close <owner/repo|.> <编号>"
  SLUG=$(resolve_slug "$1"); NUM=$2; need_num "$NUM"
  need_gh; need_token
  ghrun api -X PATCH "repos/$SLUG/pulls/$NUM" -f state=closed --jq '.state' >/dev/null
  kv PR "$NUM"
  kv STATE closed
  echo "OK"
}

cmd_pr_comment() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG pr-comment <owner/repo|.> <编号> <正文>"
  SLUG=$(resolve_slug "$1"); NUM=$2; BODY=$3; need_num "$NUM"
  need_gh; need_token
  # PR 的评论走 issues 端点：GitHub 上 PR 就是带代码的 issue
  ghrun api -X POST "repos/$SLUG/issues/$NUM/comments" -f "body=$BODY" --jq '.id' >/dev/null
  kv PR "$NUM"
  kv COMMENTED yes
  echo "OK"
}

# ---- Issue ------------------------------------------------------------------

cmd_issue_create() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG issue-create <owner/repo|.> <标题> <正文|-> [标签逗号分隔]"
  SLUG=$(resolve_slug "$1"); TITLE=$2; BODY=$(body_arg "$3"); LABELS=${4:-}
  need_gh; need_token
  if [ -n "$LABELS" ]; then
    # 带标签时必须整体发 JSON：gh api 的 -f 与 --input 不能混用，
    # 而 labels 是数组字段，用 -f 拼不出来
    _lj=$(printf '%s' "$LABELS" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"}')
    OUT=$(printf '{"title":"%s","body":"%s","labels":%s}' \
      "$(printf '%s' "$TITLE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
      "$(printf '%s' "$BODY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')" \
      "$_lj" | ghrun api -X POST "repos/$SLUG/issues" --input - --jq '.html_url') || exit $?
  else
    OUT=$(ghrun api -X POST "repos/$SLUG/issues" -f "title=$TITLE" -f "body=$BODY" --jq '.html_url') || exit $?
  fi
  kv ISSUE_URL "$OUT"
  kv ISSUE_NUMBER "$(printf '%s' "$OUT" | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p' | head -1)"
  echo "OK"
}

cmd_issue_list() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG issue-list <owner/repo|.> [open|closed|all] [数量]"
  SLUG=$(resolve_slug "$1"); STATE=${2:-open}; LIM=${3:-20}
  need_gh; need_token
  tsv_header "number state title"
  ghrun api "repos/$SLUG/issues?state=$STATE&per_page=$LIM" \
    --jq '.[] | select(.pull_request == null) | "\(.number)\t\(.state)\t\(.title)"'
}

cmd_issue_close() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG issue-close <owner/repo|.> <编号>"
  SLUG=$(resolve_slug "$1"); NUM=$2; need_num "$NUM"
  need_gh; need_token
  ghrun api -X PATCH "repos/$SLUG/issues/$NUM" -f state=closed --jq '.state' >/dev/null
  kv ISSUE "$NUM"
  kv STATE closed
  echo "OK"
}

cmd_issue_comment() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG issue-comment <owner/repo|.> <编号> <正文>"
  SLUG=$(resolve_slug "$1"); NUM=$2; BODY=$3; need_num "$NUM"
  need_gh; need_token
  ghrun api -X POST "repos/$SLUG/issues/$NUM/comments" -f "body=$BODY" --jq '.id' >/dev/null
  kv ISSUE "$NUM"
  kv COMMENTED yes
  echo "OK"
}

# ---- Actions ----------------------------------------------------------------

cmd_ci_list() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG ci-list <owner/repo|.> [数量]"
  SLUG=$(resolve_slug "$1"); LIM=${2:-10}
  need_gh; need_token
  tsv_header "run_id status conclusion workflow branch"
  ghrun api "repos/$SLUG/actions/runs?per_page=$LIM" \
    --jq '.workflow_runs[] | "\(.id)\t\(.status)\t\(.conclusion // "-")\t\(.name)\t\(.head_branch)"'
}

cmd_ci_view() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG ci-view <owner/repo|.> <run-id>"
  SLUG=$(resolve_slug "$1"); RID=$2; need_num "$RID"
  need_gh; need_token
  ghrun api "repos/$SLUG/actions/runs/$RID" \
    --jq '"RUN_ID=\(.id)\nSTATUS=\(.status)\nCONCLUSION=\(.conclusion // "-")\nWORKFLOW=\(.name)\nBRANCH=\(.head_branch)\nEVENT=\(.event)\nURL=\(.html_url)"'
}

cmd_ci_run() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG ci-run <owner/repo|.> <workflow文件名或ID> [ref分支]"
  SLUG=$(resolve_slug "$1"); WF=$2; REF=${3:-}
  need_gh; need_token
  if [ -n "$REF" ]; then
    ghrun workflow run "$WF" -R "$SLUG" --ref "$REF" >/dev/null
    kv REF "$REF"
  else
    ghrun workflow run "$WF" -R "$SLUG" >/dev/null
    kv REF "默认分支"
  fi
  kv TRIGGERED "$WF"
  echo "OK"
}

cmd_ci_logs() {
  [ $# -ge 3 ] || die1 "用法: sh $PROG ci-logs <owner/repo|.> <run-id> <输出文件>"
  SLUG=$(resolve_slug "$1"); RID=$2; OUT=$3; need_num "$RID"
  need_gh; need_token
  # 日志可能几十 MB，只落文件不回显：塞进对话会把上下文一次吃光
  ghrun run view "$RID" -R "$SLUG" --log > "$OUT" || die4 "下载日志失败"
  kv LOG_FILE "$OUT"
  kv LOG_LINES "$(wc -l < "$OUT" | tr -d ' ')"
  echo "OK"
}

# ---- Gist -------------------------------------------------------------------

cmd_gist_create() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG gist-create <描述> <文件...>"
  DESC=$1; shift
  need_gh; need_token
  [ -f "$1" ] || die2 "文件不存在: $1"
  # 默认就是 secret，不要传 --secret：gh 2.x 根本没有这个 flag，传了会 `unknown flag`。
  # 想要公开必须显式加 --public —— 公开 gist 会被搜索引擎收录且无法撤回，不适合做默认。
  OUT=$(ghrun gist create "$@" --desc "$DESC") || exit $?
  kv GIST_URL "$OUT"
  kv GIST_ID "$(printf '%s' "$OUT" | sed 's#.*/##')"
  kv VISIBILITY secret
  echo "OK"
}

cmd_gist_list() {
  LIM=${1:-20}
  need_gh; need_token
  tsv_header "id visibility description files"
  ghrun api "gists?per_page=$LIM" \
    --jq '.[] | "\(.id)\t\(if .public then "public" else "secret" end)\t\(.description // "-")\t\(.files | keys | join(","))"'
}

cmd_gist_view() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG gist-view <gist-id>"
  GID=$1
  need_gh; need_token
  ghrun api "gists/$GID" \
    --jq '"GIST_ID=\(.id)\nVISIBILITY=\(if .public then "public" else "secret" end)\nDESC=\(.description // "-")\nFILES=\(.files | keys | join(","))\nURL=\(.html_url)"'
}

cmd_gist_get() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG gist-get <gist-id> <输出文件> [文件名]"
  GID=$1; OUT=$2; FNAME=${3:-}
  need_gist_id "$GID"
  need_gh; need_token
  if [ -n "$FNAME" ]; then
    _raw=$("$GH" api "gists/$GID" --jq ".files[\"$FNAME\"].raw_url" 2>/dev/null)
  else
    _raw=$("$GH" api "gists/$GID" --jq '.files | to_entries[0].value.raw_url' 2>/dev/null)
  fi
  [ -n "$_raw" ] && [ "$_raw" != "null" ] || die4 "取不到文件（gist 不存在或文件名不对）"
  # raw_url 是 30 天有效的临时签名地址，不需要令牌；这里用 curl 只为少一层 gh 输出加工
  curl -sS -m 120 -L "$_raw" -o "$OUT" || die4 "下载失败"
  kv FILE "$OUT"
  kv BYTES "$(wc -c < "$OUT" | tr -d ' ')"
  echo "OK"
}

cmd_gist_delete() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG gist-delete <gist-id> <复述同名 gist-id>"
  GID=$1
  gate_confirm "$GID" "$2"
  need_gh; need_token
  # --yes 是给 gh 的机器可读确认（非交互环境必需）；语义上的复述闸门在上面，不冲突
  ghrun gist delete "$GID" --yes >/dev/null
  kv DELETED "$GID"
  echo "OK"
}

# ---- 透传 -------------------------------------------------------------------

cmd_api() {
  [ $# -ge 1 ] || die1 "用法: sh $PROG api <gh api 的参数...>"
  need_gh; need_token
  ghrun api "$@"
}

CMD=$1
[ $# -gt 0 ] && shift

case "$CMD" in
  repo-view)   [ $# -ge 1 ] || die1 "用法: sh $PROG repo-view <owner/repo|.>"; cmd_repo_view "$@" ;;
  repo-list)   cmd_repo_list "$@" ;;
  repo-edit)   cmd_repo_edit "$@" ;;
  repo-delete) cmd_repo_delete "$@" ;;
  repo-clone)  cmd_repo_clone "$@" ;;
  pr-create)   cmd_pr_create "$@" ;;
  pr-list)     cmd_pr_list "$@" ;;
  pr-view)     cmd_pr_view "$@" ;;
  pr-merge)    cmd_pr_merge "$@" ;;
  pr-close)    cmd_pr_close "$@" ;;
  pr-comment)  cmd_pr_comment "$@" ;;
  issue-create)  cmd_issue_create "$@" ;;
  issue-list)    cmd_issue_list "$@" ;;
  issue-close)   cmd_issue_close "$@" ;;
  issue-comment) cmd_issue_comment "$@" ;;
  ci-list)     cmd_ci_list "$@" ;;
  ci-view)     cmd_ci_view "$@" ;;
  ci-run)      cmd_ci_run "$@" ;;
  ci-logs)     cmd_ci_logs "$@" ;;
  gist-create) cmd_gist_create "$@" ;;
  gist-list)   cmd_gist_list "$@" ;;
  gist-view)   cmd_gist_view "$@" ;;
  gist-get)    cmd_gist_get "$@" ;;
  gist-delete) cmd_gist_delete "$@" ;;
  api)         cmd_api "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  "") usage; exit 1 ;;
  *) err "未知子命令: $CMD"; usage; exit 1 ;;
esac
