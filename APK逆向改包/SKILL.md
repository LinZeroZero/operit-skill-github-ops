---
name: APK逆向改包
description: 反编译 APK、改默认值/开关/常量/资源/标识，再回编译重签名并验证。适用「改默认设置」「反编译看逻辑」「重打包/签名/装不上」。用 apk_reverse 包，设备即目标机，无需 adb。
---

# APK 逆向改包

目标只有一个：把 APK 改到「按改后的样子跑起来」，并证明它真的生效。
底稿 `2233admin/reverse-skill-evolver`（MIT），已裁掉 `.ps1`/`adb`/`ida`，换成本机实测可用的工具链。

## 0. 四个前提

先读这一段：后面每一句命令都由它决定。

| 前提 | 事实 | 所以 |
| --- | --- | --- |
| 回编译只能在 proot | Operit 域是 `untrusted_app`，Android 禁止它 exec 自己数据目录里的可执行文件，而 apktool 的 build 必须 exec 一个 aapt2 | `apk_reverse_build` / `build_and_sign` 必然失败（`error=13` 或 `exit code 132`），不是包坏了 |
| 签名可以在 App 内做 | apksig 是纯 Java，不 exec 外部程序 | `apk_reverse_sign` 可用，于是 build/sign 拆成两段也顺 |
| 工作区必须放私有 f2fs | 同一 7MB APK：decode 到私有目录 24.8 秒，到 `/sdcard`（FUSE）115 秒；写 600 个小文件 26ms vs 331ms | 放 /sdcard 会让每轮作业慢 4.6 倍，一次 decode 还会摊开 130MB / 11,288 个文件 |
| `cache/aapt2_*.tmp` 不要删 | 那是 apktool 解压的 aapt2 本体（4,706,040 B）。**proot 回编译不读它**（用的是 `/root/tools/sdk/build-tools/aapt2`），只有 App 内 build 会读 | 它不属于垃圾；万一被清，按 `references/toolchain` 的「aapt2 应急恢复」提回（只影响 App 内 build） |

## 1. 分工：哪些在 App 内，哪些在 proot

| 步骤 | 在哪跑 | 用什么 |
| --- | --- | --- |
| 体检 | App 内 | `apk_reverse_inspect` |
| 解包 | App 内 | `apk_reverse_decode` |
| 读 Java（按需） | App 内 | `apk_reverse_jadx` |
| 定位/反查 | App 内 | `apk_reverse_search_text`、`apk_reverse_search_address` |
| **回编译** | **Ubuntu/proot** | `java -jar /root/tools/apktool.jar b ...` |
| **签名** | App 内 | `apk_reverse_sign` |
| 装卸包 | Android root | `su -c pm install / uninstall` |

参数细节见 `references/toolchain-apk_reverse.md`，不要凭记忆传参。

## 2. 工作区：apkw.sh

脚本在 `/sdcard/Download/Operit/skills/APK逆向改包/scripts/apkw.sh`。分区是 noexec，只能
`sh 脚本路径` 调用；需要 root（要把工作区 chown 回 App）。

```sh
S='/sdcard/Download/Operit/skills/APK逆向改包/scripts/apkw.sh'
sh "$S" new /path/to/app.apk    # 输出 WORK_DIR / DECODED / JADX_OUT / PATCHED / NOTES 与 STATE（必要时带 NOTE）
sh "$S" list                    # 各工作区占用降序
sh "$S" clean -f                # 清 jadx_out 与 cache/jadx-temp-*；不带 -f 是 dry-run
sh "$S" drop d2cb5da8 -f        # 删工作区（d2cb5da8 换成 目录名）；不带 -f 是 dry-run
```

四个必须知道的点：

- 命令里的 `<xxx>` 是占位符、`[-f]` 是可选项，换成实际值再执行。`<` 在 shell 里是重定向符，
  原样复制会**静默失败**：变量被赋成空值，`rc` 仍是 0，看不出错。
- 目录名 = 源 APK 的 sha256 前 8 位。判据是“`decoded/` 里有没有文件”，不是“目录在不在”——
  空目录（上次 decode 半途失败）不会误报可用。`STATE=reused` = 可直接回编译，
  省掉一次 25–115 秒的 decode；`STATE=fresh` 表示还得先 decode，若附带 `NOTE=` 就按它办（空 `decoded/` 先删掉再解包）。
- root 建的目录不 chown 给 App 的 uid，decode 就写不进去（而且报错点在工具里，看起来像工具坏了）。
- `decoded/` 默认保留，只有 `drop` 才删；`jadx_out/` 读完即废，`clean` 默认清它。

## 3. 三条硬规则

**R1 先判层，再动手。** 改动可能落在四层：资源表、smali、native `.so`、服务端。改错层不会报错，
只会「编译通过、能启动、行为没变」。出现这种情形就回第 4 节重新判层，不要在原层加码重试。

**R2 一次只改一个变量。** 「改包无效」这类结论必须单独一轮复现；一次改三处，失败了也定位不到原因。

**R3 未验证不算完成。** 编译成功 ≠ 能用，进程起来 ≠ 功能生效。必须装到设备、手动走到被改的功能、
看到屏幕变化，并用哈希确认跑的是新包。

## 4. 先选路线

```
改的是「运行时数据」还是「包里写死的东西」？
├─ 应用自己也允许运行期变化的（开关、缓存路径、上次选择）
│   └─ 走 A：root 直改 /data/data/<pkg>，不动签名、不重装、可逆
└─ 默认值 / 常量 / 分支 / 门槛 / 标识 / 资源外观
    └─ 走 B：decode → 定位 → 改 → build（proot）→ sign（App 内）
        B 再看改哪层：
        ├─ res/values/*.xml → 改资源，smali 不动（最省事）
        ├─ 逻辑在 Java（jadx 能读）→ 改 smali，jadx 只用来读懂
        ├─ 逻辑在 lib/arm64-v8a/*.so → 非目标：smali 层 stub 调用，或说明需 IDA/radare2
        └─ 逻辑在服务端（价格、权限、内容）→ 客户端改不动，直接给结论
```

## 5. 路线 B 的流程

**① 体检** `apk_reverse_inspect`：包名、版本、主 activity、签名摘要、dex 数、`lib/` 有无 `.so`、
是否 split。`.so` 多就先预判核心逻辑在 native，别白读 Java；多个 split 时只 decode `base.apk`，
config split 里的资源要单独处理。

**② 解包** `apkw.sh new` → `STATE=reused` 就跳过 decode，否则 `apk_reverse_decode` 到 `DECODED`；
出现 `NOTE=` 时按它办（多半是空 `decoded/` 或没解过包）。
只有 `decoded/` 能回编译，所有修改都落这里。

**③ 定位：先搜再读。** 顺序固定 `search → 缩到文件 → 再读`，不要打开 jadx 目录全局通读。

| 想找的东西 | 关键词模板 |
| --- | --- |
| 设置项键名 | `shared_pref`、`preferences`、`getBoolean`、`getString` |
| 开关/门槛 | `isVip`、`isPro`、`isEnabled`、`trial` |
| 广告/统计 | `AdRequest`、`loadAd`、`firebase`、`umeng` |
| 地址/接口 | `https?://`、`BASE_URL`、`api/` |
| 版本/渠道 | `VERSION_NAME`、`channel` |
| 校验/加固 | `signature`、`getPackageInfo`、`GET_SIGNATURES` |

`scope` 收紧到 `smali`/`res`/`manifest`，配 `max_results` 限条数；`native_strings` 很贵，非必要不开。
只有命中读不出 Java 语义时才开 `apk_reverse_jadx`，读完即删。混淆重到 jadx 也读不动就切 smali，
类名乱码不影响定位逻辑。
进第 ④ 步前必须回答：改哪个文件、哪一行、这段路径会不会被别处覆盖或短路。

**④ 最小改。** 手法按层，完整示例见 `references/patch-layers.md`。核心只有一句：**改返回值最稳，
不重写方法体**——`.locals` 之后插 `const/4 v0, 0x1` + `return v0`，寄存器号必须小于声明数。
资源层注意 `values-xx/` 会覆盖默认值；改包名除 `package=` 还要同步 provider `authorities`、
自定义 `permission`、硬编码包名字符串。

**⑤ 回编译（proot）。** 改完 `decoded/` 后：

```sh
H=d2cb5da8    # 换成 apkw.sh new 回显的目录名（源包 sha256 前 8 位）
D=/data/data/com.ai.assistance.operit/files/apkwork/$H/decoded
java -jar /root/tools/apktool.jar b "$D" -o /root/tools/out/out.apk --aapt /root/tools/sdk/build-tools/aapt2
```

- `--aapt` **必须显式给**：apktool 3.0.1 默认解压自带的 x86_64 aapt2，arm64 上直接 `exit code = 132`（SIGILL）。
- proot 能直接读写私有工作区，build 也吃 f2fs 速度，不用把 130MB 拷到 /sdcard。
- `/root/tools/out/` 在 proot 镜像内，App 看不到；签名前必须 `cp` 出来：
  `cp /root/tools/out/out.apk /sdcard/Download/out.apk`

**⑥ 签名（App 内）。** `apk_reverse_sign`：`input_apk_path` + `output_apk_path` + `sign_mode`。
`debug` 用内置 keystore（`/data/user/0/com.ai.assistance.operit/files/pkcs12.keystore`，alias `androidkey`），
**签名与原包必然不同**；`keystore` 模式要 `keystore_path`/`storepass`/`alias`。

**⑦ 装机验证。** 签名变了不能覆盖原包（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）：卸载重装，或改包名共存。
装完走完六项，缺一项不算完成：

1. 哈希核对（`pm path 包名` 取路径后算哈希）
2. 冷启动能过启动页
3. 目标功能肉眼确认生效
4. 走一条相邻路径，没连带崩
5. `logcat` 无因本次改动新增的异常
6. 结论写明：成立 / 卡在哪一层

**⑧ 收尾。** `sh "$S" clean -f`；`decoded/` 留着供迭代，腾空间时 `list` 看占用再 `drop 目录名 -f`。

## 6. 路线 A：root 直改运行期配置

```sh
PKG=com.example.app                             # 换成目标包名，下面可直接复制
su -c am force-stop $PKG                        # 不先停，内存旧值会回写
su -c ls /data/data/$PKG/shared_prefs/          # 目标通常是 ${PKG}_preferences.xml
su -c cp /data/data/$PKG/shared_prefs/x.xml /sdcard/tmp/x.xml
# 改 /sdcard/tmp/x.xml（不要原地 sed，容易写坏 XML）
su -c cp /sdcard/tmp/x.xml /data/data/$PKG/shared_prefs/x.xml
uid=$(su -c stat -c %u /data/data/$PKG)
su -c chown $uid:$uid /data/data/$PKG/shared_prefs/x.xml
su -c chmod 660 /data/data/$PKG/shared_prefs/x.xml
```

属主/权限错会静默回默认值，看起来像「没改成功」——这是本路线最常见的假失败。
值被立刻改回，说明有服务端或启动逻辑重写，这条路不通，转 B。

优点：不动签名、不丢数据、可逆（改前备份）。缺点：只能改运行期数据，改不了默认值。

## 7. 症状速查

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名与原包不同 | 卸载重装或改包名，没有第三条路 |
| 改了没效果（最高频） | 判层错：改在 jadx_out / 分支不在执行路径 / 值被服务端覆盖 / 设备已有旧值 | 依次排查，`pm clear` 复测默认值 |
| build 报 `exit code = 132` | 没带 `--aapt`，用了 x86_64 的 aapt2 | 加 `--aapt /root/tools/sdk/build-tools/aapt2` |
| build 报 `error=13 Permission denied` | 在 App 内调了 build / build_and_sign | 改在 proot 里跑 |
| build 报找不到 aapt2 | `cache/aapt2_*.tmp` 被清理了 | 按 `references/toolchain` 的「aapt2 应急恢复」提回；proot 回编译不受影响 |
| 只改一个字符串就闪退 | 应用对重打包有完整性/签名校验或加固 | 先判定校验（搜 `signature`、`getPackageInfo`），不要继续改功能 |
| 界面文案变了但功能没变 | 改的是展示字符串，真开关在别处 | 用文案反查 key，再查 key 的使用点 |
| `VerifyError` / 寄存器越界 | 插入指令的 vN ≥ `.locals` | 改 `.locals` 或换小寄存器 |
| 改完过一会儿变回去 | 启动时从服务端/数据库回写 | 服务端真相，转「改默认值 + 断同步」或放弃 |

更多见 `references/symptoms.md`。

## 8. 交付标准

每次任务至少说清楚：包名与版本、改前改后签名状态、改动落在哪层/哪个文件/哪一行、是否重打包与
如何安装、六项验证过了哪几项、失败卡在哪层与下一步。同时写进工作区 `NOTES`。

禁止：

- 没 `inspect`、没定位到类就改 smali。
- 把 `jadx_out` 当修改对象（它不可回编译）。
- 一次改多处，或把「编译成功」当结论。
- 在 App 内调 build / build_and_sign，并为它的失败反复重试。
- 清 `cache/aapt2_*.tmp`。
- 伪造或替换他人签名证书；本技能只用于你有权修改的应用。

## 9. 按需读取

- `references/toolchain-apk_reverse.md` —— 参数表、调用顺序、能力边界、可选加装
- `references/patch-layers.md` —— 五类改动的最小改法（资源 / smali / prefs / manifest / 包名）
- `references/symptoms.md` —— 症状 → 原因 → 处理

路径均为 `/sdcard/Download/Operit/skills/APK逆向改包/` 下。
