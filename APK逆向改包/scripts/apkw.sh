#!/system/bin/sh
# apkw.sh —— APK 改包的工作区管理器
#
# 在流程里的位置
#   new → apk_reverse_decode → 改文件 → proot build → sign → 安装验证
#   本脚本只管第一步的目录命名、属主与清理；改包动作一概不做。
#
# 为什么工作区必须在私有 f2fs
#   一次 decode 摊开 1.1 万个小文件、130MB（约 19 倍）。ping 2.0.17（7MB）实测：私有 24.8 秒，
#   /sdcard(FUSE) 115 秒；写 600 个小文件 26ms vs 331ms。所以只有成品才回 /sdcard。
#
# 四条不变式（改代码前先读：破了哪条都不会报错，只会静默错下去）
#   C1 目录名 = 源 APK 的 sha256 前 8 位 —— 一个包一个目录，不并存两份解包产物。
#   C2 目录由 root 建，属主必须交还 App（见 fix_owner）—— 否则工具写不进去，而报错点
#      在 decode 里，看着像工具本身坏了。
#   C3 删除只用 find -depth -delete —— 本机 shell 拦 rm -rf；toybox 会逐条打印被删路径，
#      必须重定向静音，否则一次清理刷上万行。
#   C4 只清 jadx_out/ 与 cache/jadx-temp-* —— cache/aapt2_*.tmp 是 apktool 解压出的
#      aapt2 本体：proot 回编译走 --aapt 指 SDK 里那份、用不到它，但 App 内 build 会读，
#      删了要从 jar 提回并重设属主/SELinux 才恢复得了（真实踩过）。
#
# 产物生命周期（「能不能删」的唯一依据）
#   decoded/     apktool 工程，唯一可回编译的东西 —— 迭代期内一直留着，只有 drop 删得掉
#   jadx_out/    反编译出来给人读的 —— 读完即废，clean 默认清它
#   patched.apk  签名成品，验证通过后才拷去 /sdcard
#   notes.md     改动记录，回滚与接手的唯一依据 —— new 建骨架：缺了会补，有了绝不覆盖
#
# 对外契约（调用方按这个解析，别只读给人看的文字）
#   退出码  0 成功（dry-run 无可清项也算）｜1 用法错误｜2 环境错误（源包或工作区不存在）
#   new     先输出 WORK_DIR / DECODED / JADX_OUT / PATCHED / NOTES，再输出 STATE=reused|fresh；
#           fresh 表示还得 decode，必要时追加一行 NOTE= 说明原因
#   其余    list / clean / drop 只输出人读文本，不承诺机器可解析
#
# 子命令
#   new <apk>            建或复用工作区（建议绝对路径），回显路径与 STATE
#   list                 各工作区占用（降序），据此决定删哪个
#   clean [-f]           清 jadx_out 与 cache/jadx-temp-*；默认 dry-run
#   drop <目录名> [-f]   删整个工作区；默认 dry-run

APP=/data/data/com.ai.assistance.operit   # 兼作属主基准
WORK=$APP/files/apkwork                   # 工作区根，落在 App 私有 f2fs
CACHE=$APP/cache                          # apktool 与 jadx 的临时目录都在这

usage() {
    cat <<'EOF'
用法：
  sh apkw.sh new <apk>           建/复用工作区（目录名 = sha256 前 8 位；建议传绝对路径）
  sh apkw.sh list                各工作区占用（降序）
  sh apkw.sh clean [-f]          清 jadx_out 与 cache/jadx-temp-*（默认 dry-run）
  sh apkw.sh drop <目录名> [-f]  删除整个工作区（默认 dry-run）
EOF
}

# fix_owner —— 把 root 建的目录交还给 App
#
# uid/gid 取自 APP 的属主，不硬编码：App 重装后 uid 会变，写死必然在某次重装后失效。
fix_owner() {
    uid=$(stat -c %u "$APP" 2>/dev/null)
    gid=$(stat -c %g "$APP" 2>/dev/null)
    [ -n "$uid" ] || return 1
    chown "$uid:$gid" "$@" 2>/dev/null
}

# cmd_new —— 建或复用工作区，回显后续要用的路径
#
# 复用判据是「decoded/ 里有没有文件」，不是「目录是否存在」：空目录很常见（上次中断、
# 手动 mkdir），若报 reused，人会跳过 decode 直接 build，然后在 apktool 里看到一串与真因
# 无关的错。notes.md 是回滚依据，规则只两条：缺了就建（手滑删掉也能补回骨架），有了绝不覆盖。
cmd_new() {
    apk=$1
    [ -n "$apk" ] || { usage; return 1; }
    [ -f "$apk" ] || { echo "ERR 源 APK 不存在：$apk" >&2; return 2; }

    # 摘要一次算完，取名和写入记录共用：省掉一次无谓的整包读取
    sha=$(sha256sum "$apk")
    sum=$(printf '%s' "$sha" | cut -c1-8)
    dir=$WORK/$sum
    fresh=0
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || return 2
        fresh=1
    fi
    fix_owner "$WORK" "$dir" || echo "WARN chown 失败，工具可能无法写入" >&2

    # 用「文件在不在」而不是「本次是否新建」：notes.md 被误删后，下次 new 应当把骨架补回来
    if [ ! -f "$dir/notes.md" ]; then
        {
            echo "# 任务记录：$sum"
            echo
            echo "源包：$apk"
            echo "sha256：$(printf '%s' "$sha" | cut -d" " -f1)"
            echo "package= versionName= 原签名="
            echo "改动层：资源 / smali / manifest / prefs"
            echo "文件与位置："
            echo "回编译请在 proot 里跑，必须带 --aapt 指 arm64 版（下面两行可直接粘贴）："
            echo "  D=$dir/decoded"
            echo "  java -jar /root/tools/apktool.jar b \"\$D\" -o /root/tools/out/out.apk --aapt /root/tools/sdk/build-tools/aapt2"
            echo "产物：patched.apk sha256="
            echo "安装方式：卸载重装 / 改包名共存"
            echo "验证：6 项中通过 __/6，结论="
        } > "$dir/notes.md"
        fix_owner "$dir/notes.md"
    fi

    # 回显 KEY=VALUE，供调用方直接取值（契约见文件头）
    echo "WORK_DIR=$dir"
    echo "DECODED=$dir/decoded"
    echo "JADX_OUT=$dir/jadx_out"
    echo "PATCHED=$dir/patched.apk"
    echo "NOTES=$dir/notes.md"
    # glob 直接展开、不 fork：判「非空」用不着为看一眼目录去起一个进程
    dec_ok=0
    for _p in "$dir/decoded"/*; do
        [ -e "$_p" ] && { dec_ok=1; break; }
    done
    if [ "$dec_ok" = "1" ]; then
        echo "STATE=reused"
    else
        echo "STATE=fresh"
        # 两种 fresh 的起因不同，分开提示；首次新建没话说，就不说
        if [ -d "$dir/decoded" ]; then
            echo "NOTE=decoded/ 存在但是空的（上次 decode 没跑完？），先删掉这个空目录再重新 decode"
        elif [ "$fresh" = "0" ]; then
            echo "NOTE=工作区已存在但还没有 decoded/，照常 decode 即可"
        fi
    fi
}

# cmd_list —— 按占用降序，让「先删哪个」一眼可见
cmd_list() {
    [ -d "$WORK" ] || { echo "（还没有工作区）"; return 0; }
    du -sk "$WORK"/* 2>/dev/null | sort -rn
    echo "---"
    du -sk "$WORK" 2>/dev/null | cut -f1 | sed "s/^/总计 KB: /"
}

# cmd_clean —— 清可清的垃圾，默认只出清单
#
# 范围严格按 C4。jadx-temp-* 又在 App 全局 cache 下，可能正被别处的 jadx 使用，所以连
# 它也只敢在 -f 时碰，并且逐条报出路径让人确认。
cmd_clean() {
    force=0
    [ "$1" = "-f" ] && force=1
    found=0

    for d in "$WORK"/*/jadx_out; do
        [ -d "$d" ] || continue
        found=1
        echo "jadx_out  $(du -sk "$d" | cut -f1) KB  $d"
        [ "$force" = "1" ] && find "$d" -depth -delete >/dev/null 2>&1
    done

    # 只碰 jadx-temp-*：aapt2_*.tmp 属于 apktool（见 C4），删了要手工恢复
    for t in "$CACHE"/jadx-temp-*; do
        [ -e "$t" ] || continue
        found=1
        echo "tmp       $(du -sk "$t" | cut -f1) KB  $t（全局，别处 jadx 正在跑时会被中断）"
        [ "$force" = "1" ] && find "$t" -depth -delete >/dev/null 2>&1
    done

    [ "$found" = "1" ] || { echo "没有可清理项"; return 0; }
    [ "$force" = "1" ] && echo "已清理" || echo "（dry-run，加 -f 才真删）"
}

# cmd_drop —— 删整个工作区，默认只出清单
#
# 删除手法同 C3。name 必须先是单层目录名：不校验的话 drop ../../cache -f 会真的删掉
# App 的 cache（aapt2 就在里面），一个错参数弄废工具链；而 du 还会如实报出体积，让人以为
# 删的只是某个工作区。
cmd_drop() {
    name=$1
    [ -n "$name" ] || { usage; return 1; }
    [ "$name" = "-f" ] && { usage; return 1; }   # 只给了开关没给目录名，算用法错而不是环境错
    case "$name" in
        */*|.*) echo "ERR 工作区名只能是单层目录名（不允许 / 或以 . 开头）：$name" >&2; return 1 ;;
    esac
    dir=$WORK/$name
    [ -d "$dir" ] || { echo "ERR 工作区不存在：$dir" >&2; return 2; }
    echo "drop      $(du -sk "$dir" | cut -f1) KB  $dir"
    if [ "$2" = "-f" ]; then
        find "$dir" -depth -delete >/dev/null 2>&1
        echo "已删除"
    else
        echo "（dry-run，加 -f 才真删）"
    fi
}

# 分发：shift 掉子命令名，其余参数原样交给各函数（参数个数由各函数自己校验）
case "$1" in
    new)   shift; cmd_new "$@" ;;
    list)  cmd_list ;;
    clean) shift; cmd_clean "$@" ;;
    drop)  shift; cmd_drop "$@" ;;
    *)     usage; exit 1 ;;
esac
