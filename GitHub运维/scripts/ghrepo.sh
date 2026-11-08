#!/bin/sh
# ghrepo.sh — 把本地目录推成 GitHub 仓库，并发出可下载的 Release
#
# 在流程里的位置：check → init → stage → commit → repo → push → release
#   check  只读体检（体积/文件数/大文件/连通性/仓库状态）
#   init   建仓并写入本环境必需的 config
#   repo   建远端仓库、设 origin、校正提交身份
#   push   推送当前分支
#   release / republish  发版与原地换包
#
# 为什么代码要分成「git 侧」与「gh 侧」两半：
#   git 侧（init/stage/commit/push）解决的是 proot + FUSE 的环境病，必须自己写死，
#   任何工具都替代不了；gh 侧（建仓/发版）只是调 API，交给 gh 更省代码也更少出错。
#
# 位置：/sdcard/Download/Operit/skills/GitHub运维/scripts/ghrepo.sh
#       /sdcard 是 noexec 挂载，所以只能 `sh <此文件>` 调用，不能直接执行。
#
# 对外契约（文档与对话都按这个写，改之前先想清谁依赖它）：
#   退出码  0=成功 1=用法 2=环境 3=令牌 4=网络/远端 5=闸门未通过
#   repo       输出 LOGIN= / REPO_URL= / CREATED=yes|no
#   push       输出 BRANCH= / PUSHED=<短提交号>
#   release    输出 TAG= / RELEASE_URL= / ASSET_URL= / ASSET_SIZE=
#   republish  额外说明 ASSET_MODE=clobber（同名原位覆盖）
#   check / doctor / assets 只读，不做任何写操作
#
# 三条不变的硬约束（换实现也不能丢）：
#   1. FUSE 上必须 core.createObject=rename，否则 git add 必失败（见 references/fuse-git.md）
#   2. 令牌只在环境变量里，remote URL 与 .git/config 永不残留凭据
#   3. 不 force push、不删远端、不改写历史（唯一例外见 SKILL.md）

set +e

PROG=ghrepo.sh
. "$(dirname "$0")/ghlib.sh"

usage() {
  cat <<'EOF'
用法: sh ghrepo.sh <子命令> [参数]

  check   <DIR>                    只读体检：体积/文件数/大文件/连通性/仓库状态
  init    <DIR>                    建仓（已存在则复用）并写入本环境必需的 config
  stage   <DIR> [路径...]          git add（省略路径 = 全部）；大仓库按批传路径
  commit  <DIR> "<提交说明>"        提交已 staged 的内容
  repo    <DIR> <仓库名> [private|public]
                                   建远端仓库（已存在则复用）、设 origin、校正提交身份
  push    <DIR>                    推送当前分支（令牌取自 GH_TOKEN 环境变量）
  release <DIR> <TAG> <标题> <资产文件> [说明.md]
                                   建 Release 并上传资产（APK 等）；说明缺省用最近提交
  republish <DIR> <TAG> <标题> <资产文件> [说明.md]
                                   已有 Release 上同名覆盖资产并更新说明（tag 不变）
  assets  <DIR> <TAG>              列出该 Release 的资产（TSV：name size url）
  doctor  <DIR>                    诊断：fs 类型、createObject、safe.directory、origin、大文件
  help                             本说明

退出码: 0 成功 / 1 用法 / 2 环境 / 3 令牌 / 4 网络或远端 / 5 闸门未通过
令牌: export GH_TOKEN=ghp_xxx   （只在环境变量里出现，不写文件、不进命令行）
EOF
}

# ---- 环境探测 ---------------------------------------------------------------

fs_type() { stat -f -c %T "$1" 2>/dev/null || echo unknown; }
is_fuse() { case "$(fs_type "$1")" in fuse*|fuseblk*) return 0 ;; esac; return 1; }

# 说明文件缺省值：不给就退回「构建自 <短提交号> + 最近提交标题」，保证 Release 不是白板
write_notes() {
  _dir=$1
  _out=$2
  printf '构建自提交 `%s`\n\n%s\n' "$(git -C "$_dir" rev-parse --short HEAD)" \
    "$(git -C "$_dir" log -1 --format=%s)" > "$_out"
}

# ---- 只读体检 ---------------------------------------------------------------

cmd_check() {
  DIR=$1; need_dir "$DIR"; need_git
  kv DIR "$DIR"
  kv FS "$(fs_type "$DIR")"
  kv GIT "$(git --version 2>/dev/null)"
  # 体积与文件数排除 .git，否则仓库建好之后这两个数字会一路虚高
  kv SIZE "$(du -sh --exclude=.git "$DIR" 2>/dev/null | cut -f1)"
  kv FILES "$(find "$DIR" -path "$DIR/.git" -prune -o -type f -print 2>/dev/null | wc -l)"
  echo "-- >40MB 的文件（GitHub 50MB 警告 / 100MB 硬上限）--"
  find "$DIR" -type f -size +40M 2>/dev/null | head -10
  echo "-- 连通性 --"
  # 这一条刻意保留 curl 而不是 gh：它要能在「gh 没装」时仍然回答「网络到底通不通」，
  # 否则排查顺序会变成先修 gh 再验网络，白绕一圈。
  kv GITHUB_HTTP "$(curl -s -o /dev/null -w '%{http_code}' -m 15 https://github.com/ 2>/dev/null)"
  if _b=$(gh_bin); then
    GH=$_b; export GH
    kv GH "$(gh_version)"
  else
    kv GH absent
  fi
  if [ -n "$GH_TOKEN" ] && [ -n "${GH:-}" ]; then
    # 带令牌时读的是真实额度，比 HTTP 状态码可靠：403 常常只是未认证额度用尽
    _rem=$("$GH" api rate_limit --jq .rate.remaining 2>/dev/null)
    kv API_REMAINING "${_rem:-unknown}"
  else
    kv API_REMAINING "unknown（未提供令牌）"
  fi
  echo "-- 仓库状态 --"
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    kv REPO yes
    kv BRANCH "$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)"
    kv ORIGIN "$(git -C "$DIR" remote get-url origin 2>/dev/null)"
    kv TRACKED "$(git -C "$DIR" ls-files | wc -l)"
    kv CREATEOBJECT "$(git -C "$DIR" config core.createObject 2>/dev/null)"
  else
    kv REPO no
  fi
}

# ---- 本地仓库 ---------------------------------------------------------------

cmd_init() {
  DIR=$1; need_dir "$DIR"; need_git

  # safe.directory 必须登记：git 比较的是 realpath，/storage/emulated/0/… 与 /sdcard/…
  # 会解析成同一处但字符串不同，两个写法都登记才不会被判 dubious ownership。
  for d in "$DIR" "$(cd "$DIR" && pwd -P 2>/dev/null)"; do
    [ -n "$d" ] || continue
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qx "$d"; then
      git config --global --add safe.directory "$d" && kv SAFE_ADDED "$d"
    fi
  done

  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    kv INIT reused
  else
    git -C "$DIR" init -q -b main || die2 "git init 失败: $DIR"
    kv INIT yes
  fi

  # FUSE 上的生死开关：不设 rename，add 一定失败（见文件头约束 1）
  if is_fuse "$DIR"; then
    git -C "$DIR" config core.createObject rename
    kv CREATEOBJECT rename
  fi
  git -C "$DIR" config core.fileMode false       # FUSE 不提供可信权限位，否则满屏 mode 变更
  git -C "$DIR" config core.autocrlf false
  git -C "$DIR" config http.postBuffer 524288000 # 默认 1MB，大仓库 push 会频繁中断
  git -C "$DIR" config http.version HTTP/1.1     # HTTP/2 在手机网络上易断流

  # 身份：没配过就先占位；repo 子命令拿到 login 后会换成真实的 GitHub noreply 身份
  if [ -z "$(git -C "$DIR" config user.email 2>/dev/null)" ]; then
    git -C "$DIR" config user.name "operit-push"
    git -C "$DIR" config user.email "operit-push@users.noreply.github.com"
    kv IDENTITY "placeholder（跑 repo 子命令后会换成真实账号）"
  else
    kv IDENTITY "$(git -C "$DIR" config user.email)"
  fi
  echo "OK"
}

cmd_stage() {
  DIR=$1; shift
  need_dir "$DIR"; need_repo "$DIR"
  [ $# -eq 0 ] && set -- .
  _tmp=$(mktemp)
  git -C "$DIR" add -A "$@" >"$_tmp" 2>&1
  _rc=$?
  tail -6 "$_tmp"; rm -f "$_tmp"
  [ "$_rc" -eq 0 ] || die2 "git add 失败（FUSE 上多半是没设 core.createObject=rename）"
  kv STAGED "$(git -C "$DIR" diff --cached --name-only | wc -l)"
}

cmd_commit() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG commit <DIR> \"提交说明\""
  DIR=$1; MSG=$2
  need_dir "$DIR"; need_repo "$DIR"
  if [ -z "$(git -C "$DIR" diff --cached --name-only)" ]; then
    echo "NOTHING_TO_COMMIT"
    echo "OK"
    return 0
  fi
  _tmp=$(mktemp)
  git -C "$DIR" commit -q -m "$MSG" >"$_tmp" 2>&1
  _rc=$?
  tail -6 "$_tmp"; rm -f "$_tmp"
  [ "$_rc" -eq 0 ] || die2 "commit 失败"
  kv COMMIT "$(git -C "$DIR" rev-parse --short HEAD)"
}

# ---- 远端仓库 ---------------------------------------------------------------

cmd_repo() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG repo <DIR> <仓库名> [private|public]"
  DIR=$1; NAME=$2; VIS=${3:-private}
  need_dir "$DIR"; need_repo "$DIR"; need_gh; need_token

  LOGIN=$(gh_login) || die3 "令牌无效或网络不通（取不到 /user；检查令牌是否过期、是否含 repo 权限）"
  kv LOGIN "$LOGIN"
  SLUG="$LOGIN/$NAME"

  # 已存在就复用：探测用 gh api 而不是 gh repo view，后者输出面向人、失败还分不清 404 与 403
  if gh_try api "repos/$SLUG" >/dev/null 2>&1; then
    CREATED=no
  else
    # 刻意不用 `gh repo create`：它的 flag 集合随版本增删，而这里要精确控制
    # has_wiki=false / has_issues=true；REST 字段是固定的，不会漂移。
    case "$VIS" in
      public) _priv=false ;;
      *)      _priv=true ;;
    esac
    ghrun api -X POST user/repos -f "name=$NAME" -F "private=$_priv" \
      -F has_issues=true -F has_wiki=false >/dev/null
    CREATED=yes
  fi

  # origin 用不含令牌的地址，令牌只在 push 时以一次性 URL 传入
  git -C "$DIR" remote remove origin >/dev/null 2>&1
  git -C "$DIR" remote add origin "https://github.com/$SLUG.git"
  git -C "$DIR" config user.name "$LOGIN"
  git -C "$DIR" config user.email "$LOGIN@users.noreply.github.com"

  # 若首个提交是在 init 的占位身份下做的，这里顺手改成本人（此时还没推送，改写历史无风险）
  if git -C "$DIR" rev-parse HEAD >/dev/null 2>&1; then
    _ae=$(git -C "$DIR" log -1 --format=%ae)
    if printf '%s' "$_ae" | grep -qE '^operit(-push)?@users\.noreply\.github\.com$'; then
      if git -C "$DIR" commit --amend --reset-author --no-edit >/dev/null 2>&1; then
        kv AUTHOR_FIXED "$(git -C "$DIR" log -1 --format=%ae)"
      fi
    fi
  fi

  kv REPO_URL "https://github.com/$SLUG"
  kv CREATED "$CREATED"
  echo "OK"
}

cmd_push() {
  DIR=$1; need_dir "$DIR"; need_repo "$DIR"; need_token
  BR=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)
  [ -n "$BR" ] || die2 "拿不到当前分支（detached HEAD？先 git switch -c main）"
  ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -n "$ORIGIN" ] || die2 "还没设 origin（先跑 repo 子命令）"

  # 支持 https://github.com/u/r.git 与 git@github.com:u/r.git 两种 origin 写法
  HOSTPATH=$(printf '%s' "$ORIGIN" | sed -e 's#^https://##' -e 's#^git@##' -e 's#:#/#' -e 's#/$##')
  AUTHURL="https://x-access-token:$GH_TOKEN@$HOSTPATH"

  kv BRANCH "$BR"
  kv PUSH_START "$(date +%T)"
  _tmp=$(mktemp)
  GIT_TERMINAL_PROMPT=0 git -C "$DIR" -c credential.helper= \
    push "$AUTHURL" "HEAD:refs/heads/$BR" >"$_tmp" 2>&1
  _rc=$?
  # 输出里可能出现带令牌的 URL，统一把 userinfo 段打码再展示
  tail -15 "$_tmp" | sed -e 's#//[^@/]*@#//***@#g'
  rm -f "$_tmp"
  [ "$_rc" -eq 0 ] || die4 "push 失败（rc=$_rc；网络/代理/令牌/大文件都可能是原因，见 references/troubleshoot.md）"

  # 上游指向不含令牌的 origin，之后 git status 才有对比基准
  git -C "$DIR" config "branch.$BR.remote" origin
  git -C "$DIR" config "branch.$BR.merge" "refs/heads/$BR"
  kv PUSHED "$(git -C "$DIR" rev-parse --short HEAD)"
  kv PUSH_END "$(date +%T)"
  echo "OK"
}

# ---- 发版 -------------------------------------------------------------------

# Release = 「发布包」：push 只把源码放进仓库，Release 才会在仓库右侧出现可下载的资产。
# 本功能用的 gh 命令刻意只覆盖「创建/上传」，所有读取一律走 gh api：
# REST 字段名固定，而 gh 的 --json 字段集随版本变（见 references/gh-json-fields.md）。
cmd_release() {
  [ $# -ge 4 ] || die1 "用法: sh $PROG release <DIR> <TAG> <标题> <资产文件> [说明.md]"
  DIR=$1; TAG=$2; TITLE=$3; ASSET=$4; NOTES=${5:-}
  need_dir "$DIR"; need_repo "$DIR"; need_gh; need_token
  [ -f "$ASSET" ] || die2 "资产文件不存在: $ASSET"
  ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -n "$ORIGIN" ] || die2 "还没设 origin（先跑 repo 子命令）"
  SLUG=$(slug_of "$ORIGIN")
  BR=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)

  # 一个 tag 只能挂一个 Release：先探明再动作，避免「建到一半 422」这种半成品状态
  if gh_try release view "$TAG" -R "$SLUG" >/dev/null 2>&1; then
    die4 "tag $TAG 的 Release 已存在：换个 tag，或改用 republish 原位替换"
  fi

  TMPN=""
  if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    SRC=$NOTES
  else
    SRC=$(mktemp); TMPN=$SRC
    write_notes "$DIR" "$SRC"
  fi

  # 建 Release 与上传资产分两步：合并成一条命令时，失败分不清是 tag 冲突还是上传中断
  # 注意 `|| exit $?`：ghrun 内部是 exit，而它在 $(...) 子 shell 里运行，
  # 不显式转发退出码的话父脚本会带着空值继续往下走（打印空的 RELEASE_URL= 与 OK）
  RELEASE_URL=$(ghrun release create "$TAG" -R "$SLUG" --title "$TITLE" \
    --notes-file "$SRC" --target "$BR") || exit $?
  [ -n "$TMPN" ] && rm -f "$TMPN"

  kv UPLOAD_START "$(date +%T)"
  ghrun release upload "$TAG" "$ASSET" -R "$SLUG" --clobber >/dev/null
  kv UPLOAD_END "$(date +%T)"

  _row=$("$GH" api "repos/$SLUG/releases/tags/$TAG" \
    --jq ".assets[] | select(.name==\"$(basename "$ASSET")\") | \"\(.size)\t\(.browser_download_url)\"" 2>/dev/null)
  [ -n "$_row" ] || die4 "上传后回读不到资产（上传可能被中断，重跑 republish 即可）"
  _size=${_row%%	*}
  _url=${_row#*	}

  kv TAG "$TAG"
  kv RELEASE_URL "$RELEASE_URL"
  kv ASSET_URL "$_url"
  kv ASSET_SIZE "$_size"
  echo "OK"
}

# republish = 在已有 Release 上「重新发布一版」，tag 不变。
# 与 release 的区别：release 撞 tag 会 422，republish 是原位更新。
# 换 gh 之后的实质改进：--clobber 让同名资产原地覆盖，不需要「先删后传」，
# 因此旧下载链接依然有效（老实现是先删再传，旧文件名一律 404）。
cmd_republish() {
  [ $# -ge 4 ] || die1 "用法: sh $PROG republish <DIR> <TAG> <标题> <资产文件> [说明.md]"
  DIR=$1; TAG=$2; TITLE=$3; ASSET=$4; NOTES=${5:-}
  need_dir "$DIR"; need_repo "$DIR"; need_gh; need_token
  [ -f "$ASSET" ] || die2 "资产文件不存在: $ASSET"
  ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -n "$ORIGIN" ] || die2 "还没设 origin（先跑 repo 子命令）"
  SLUG=$(slug_of "$ORIGIN")

  if ! gh_try release view "$TAG" -R "$SLUG" >/dev/null 2>&1; then
    echo "RELEASE_NOT_FOUND=$TAG（改为新建）"
    cmd_release "$@"
    return $?
  fi

  TMPN=""
  if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    SRC=$NOTES
  else
    SRC=$(mktemp); TMPN=$SRC
    write_notes "$DIR" "$SRC"
  fi

  # 先改元信息再传包：万一上传中断，标题/说明已经是对的，重跑一次即可
  ghrun release edit "$TAG" -R "$SLUG" --title "$TITLE" --notes-file "$SRC" >/dev/null
  [ -n "$TMPN" ] && rm -f "$TMPN"

  kv UPLOAD_START "$(date +%T)"
  ghrun release upload "$TAG" "$ASSET" -R "$SLUG" --clobber >/dev/null
  kv UPLOAD_END "$(date +%T)"

  _row=$("$GH" api "repos/$SLUG/releases/tags/$TAG" \
    --jq ".assets[] | select(.name==\"$(basename "$ASSET")\") | \"\(.size)\t\(.browser_download_url)\"" 2>/dev/null)
  [ -n "$_row" ] || die4 "上传后回读不到资产（上传可能被中断，重跑一次即可）"
  _size=${_row%%	*}
  _url=${_row#*	}

  _html=$("$GH" api "repos/$SLUG/releases/tags/$TAG" --jq .html_url 2>/dev/null)

  kv TAG "$TAG"
  kv RELEASE_URL "$_html"
  kv ASSET_URL "$_url"
  kv ASSET_SIZE "$_size"
  kv ASSET_MODE "clobber（同名原位覆盖，旧链接仍有效）"
  echo "OK"
}

# 只读：列出某 tag 下的资产。诊断「包到底传上去没有 / 传了几份」时用。
cmd_assets() {
  [ $# -ge 2 ] || die1 "用法: sh $PROG assets <DIR> <TAG>"
  DIR=$1; TAG=$2
  need_dir "$DIR"; need_gh; need_token
  ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -n "$ORIGIN" ] || die2 "还没设 origin"
  SLUG=$(slug_of "$ORIGIN")
  tsv_header "name size url"
  "$GH" api "repos/$SLUG/releases/tags/$TAG" \
    --jq '.assets[] | "\(.name)\t\(.size)\t\(.browser_download_url)"' 2>/dev/null \
    || die4 "读取资产失败（tag 不存在，或令牌无权访问）"
}

cmd_doctor() {
  DIR=$1; need_dir "$DIR"; need_git
  kv DIR "$DIR"
  kv FS "$(fs_type "$DIR")"
  kv GIT "$(git --version 2>/dev/null)"
  if _b=$(gh_bin); then
    GH=$_b; export GH
    kv GH "$(gh_version)"
    gh_version_ok && kv GH_OK yes || kv GH_OK "no（需 2.${GH_MIN_MINOR}+）"
  else
    kv GH absent
    kv GH_OK no
  fi
  if is_fuse "$DIR"; then
    _co=$(git -C "$DIR" config core.createObject 2>/dev/null)
    case "$_co" in
      rename) kv CREATEOBJECT "rename(ok)" ;;
      *)      kv CREATEOBJECT "${_co:-unset}(需要 rename，否则 add 必失败)" ;;
    esac
  fi
  kv SAFE "$(git config --global --get-all safe.directory 2>/dev/null | tr '\n' ' ')"
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    kv REPO yes
    kv BRANCH "$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)"
    kv ORIGIN "$(git -C "$DIR" remote get-url origin 2>/dev/null)"
    kv TRACKED "$(git -C "$DIR" ls-files | wc -l)"
    git -C "$DIR" count-objects -v 2>/dev/null | grep -E '^(count|size|garbage):' | sed 's/^/OBJ_/'
  else
    kv REPO no
  fi
  kv OVER_100MB "$(find "$DIR" -type f -size +100M 2>/dev/null | wc -l)"
  [ -n "$GH_TOKEN" ] && kv TOKEN present || kv TOKEN absent
}

CMD=$1
[ $# -gt 0 ] && shift

case "$CMD" in
  check)   [ $# -ge 1 ] || die1 "用法: sh $PROG check <DIR>";  cmd_check  "$1" ;;
  init)    [ $# -ge 1 ] || die1 "用法: sh $PROG init <DIR>";   cmd_init   "$1" ;;
  stage)   [ $# -ge 1 ] || die1 "用法: sh $PROG stage <DIR> [路径...]"; cmd_stage "$@" ;;
  commit)  [ $# -ge 2 ] || die1 "用法: sh $PROG commit <DIR> \"提交说明\""; cmd_commit "$@" ;;
  repo)    [ $# -ge 2 ] || die1 "用法: sh $PROG repo <DIR> <仓库名> [private|public]"; cmd_repo "$@" ;;
  push)    [ $# -ge 1 ] || die1 "用法: sh $PROG push <DIR>";   cmd_push   "$1" ;;
  release) [ $# -ge 4 ] || die1 "用法: sh $PROG release <DIR> <TAG> <标题> <资产文件> [说明.md]"; cmd_release "$@" ;;
  republish) [ $# -ge 4 ] || die1 "用法: sh $PROG republish <DIR> <TAG> <标题> <资产文件> [说明.md]"; cmd_republish "$@" ;;
  assets)  [ $# -ge 2 ] || die1 "用法: sh $PROG assets <DIR> <TAG>"; cmd_assets "$@" ;;
  doctor)  [ $# -ge 1 ] || die1 "用法: sh $PROG doctor <DIR>"; cmd_doctor "$1" ;;
  help|-h|--help) usage; exit 0 ;;
  "") usage; exit 1 ;;
  *) err "未知子命令: $CMD"; usage; exit 1 ;;
esac