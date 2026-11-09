#!/system/bin/sh
# 一句话：把「GitHub运维」技能装到 Operit 的技能目录。
#
# 三个取舍写在前面，改之前先读：
#   1. 只依赖 curl + tar。Android 的 /system/bin 自带 toybox 的这两个命令（实测 0.8.12），
#      但不保证有 unzip，所以发布物是 .tar.gz 而不是 .zip。
#   2. 先落盘再解包。`curl | tar` 实测可用，但链路抖动时管道会把半截数据喂给 tar，
#      结果解出残缺目录却返回成功。落盘后先用 `tar -tzf` 过一遍清单就能拦住这种包。
#   3. 覆盖前先备份。技能目录是用户会手改的地方，直接覆盖等于销毁他的改动，
#      所以已存在时把旧目录改名成 <名>.bak.<时间戳>；想干净覆盖加 --force。
#
# 退出码：0 成功 1 用法错误 2 环境缺命令 3 下载失败 4 解包失败 5 校验失败
set -u

SKILL="GitHub运维"
ASSET="github-ops.tar.gz"
REPO="LinZeroZero/operit-skill-github-ops"
DEFAULT_ROOT="/sdcard/Download/Operit/skills"

FORCE=0
CHECK_ONLY=0
ROOT=""

die() { printf 'ERROR: %s\n' "$1" >&2; exit "$2"; }

usage() {
  cat >&2 <<'EOF'
用法: sh install.sh [选项] [技能根目录]

  （无参数）           装到 /sdcard/Download/Operit/skills
  <根目录>             装到指定根目录（想先试装就指到别处）
  --check              只报告当前安装状态，不下载
  --force              已安装时直接覆盖，不备份

示例:
  sh install.sh                       # 标准安装
  sh install.sh /sdcard/tmp/skills    # 试装到别处，不影响现有技能
  sh install.sh --check               # 看现在装的是什么

退出码: 0 成功 | 1 用法 | 2 缺 curl/tar | 3 下载失败 | 4 解包失败 | 5 校验失败
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *)  ROOT="$1" ;;
  esac
  shift
done

[ -n "$ROOT" ] || ROOT="$DEFAULT_ROOT"
ROOT=${ROOT%/}
TARGET="$ROOT/$SKILL"

# --check 只读：报告路径、文件数、体积，方便升级前先看清现状
if [ "$CHECK_ONLY" = 1 ]; then
  if [ -f "$TARGET/SKILL.md" ]; then
    printf 'INSTALLED=yes\nPATH=%s\nFILES=%s\nSIZE=%s\n' \
      "$TARGET" \
      "$(find "$TARGET" -type f 2>/dev/null | wc -l | tr -d ' ')" \
      "$(du -sh "$TARGET" 2>/dev/null | cut -f1)"
  else
    printf 'INSTALLED=no\nPATH=%s\n' "$TARGET"
  fi
  exit 0
fi

# 这两个命令决定了「零依赖安装」能不能成立，缺了就直接说清楚去哪弄
command -v curl >/dev/null 2>&1 || die "缺 curl（Android 自带 /system/bin/curl；proot 内 apt install curl）" 2
command -v tar  >/dev/null 2>&1 || die "缺 tar（Android 自带 /system/bin/tar；proot 内 apt install tar）" 2

URL="https://github.com/$REPO/releases/latest/download/$ASSET"

# 临时文件优先放 /data/local/tmp（Android 上一定可写）；proot 里该路径可能不可写，
# 此时退回目标根目录下的隐藏文件，保证脚本两边都能跑。
TMP="/data/local/tmp/$ASSET"
if ! ( : > "$TMP" ) 2>/dev/null; then
  mkdir -p "$ROOT" 2>/dev/null || die "无法创建 $ROOT" 4
  TMP="$ROOT/.$ASSET.part"
  ( : > "$TMP" ) 2>/dev/null || die "找不到可写的临时目录（试过 /data/local/tmp 与 $ROOT）" 2
fi

printf '下载: %s\n' "$URL"
curl -fL --retry 2 --connect-timeout 20 -o "$TMP" "$URL" \
  || die "下载失败。可手动下载后解到 $ROOT：$URL" 3

# 只读清单验包：半截的 gzip 在这里就会失败，不会污染技能目录
tar -tzf "$TMP" >/dev/null 2>&1 || die "包损坏或不是 tar.gz（大概率没下完整，删掉重试）" 4
printf '包校验通过: %s 字节\n' "$(wc -c < "$TMP" | tr -d ' ')"

if [ -d "$TARGET" ] && [ "$FORCE" = 0 ]; then
  BAK="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  mv "$TARGET" "$BAK" || die "无法把旧版本挪到 $BAK（磁盘满或权限不足）" 4
  printf '旧版本已备份: %s\n' "$BAK"
fi

mkdir -p "$ROOT" || die "无法创建 $ROOT" 4
tar -xzf "$TMP" -C "$ROOT" || die "解包失败" 4

# 校验点只有 SKILL.md：Operit 靠它识别技能目录，缺了等于没装
[ -f "$TARGET/SKILL.md" ] || die "解包后没有 $TARGET/SKILL.md，包结构可能不对" 5

rm -f "$TMP" 2>/dev/null

printf '\n装好了: %s\n' "$TARGET"
printf '文件数: %s\n' "$(find "$TARGET" -type f | wc -l | tr -d ' ')"
printf '体积:   %s\n' "$(du -sh "$TARGET" 2>/dev/null | cut -f1)"
printf '\n下一步: 对 Operit 里的 AI 说「用%s技能」，它会自己读 SKILL.md。\n' "$SKILL"
