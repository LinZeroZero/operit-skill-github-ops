# 工具链速查（apk_reverse 包，本机实测）

全部工具来自 `apk_reverse` 包，调用方式 `use_package("apk_reverse")` 之后用包内工具。
路径一律写 Android 侧绝对路径（`/sdcard/...`、`/storage/emulated/0/...`），写 Linux 沙箱路径会失败。

## 参数表

### apk_reverse_inspect
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_apk_path` | 是 | 目标 APK 绝对路径 |

产出：包名、versionName/versionCode、主 activity、组件与权限、签名文件摘要、dex 与 `lib/<abi>/*.so`
分布。**每次任务第一条命令**，不改任何文件。

### apk_reverse_decode
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_apk_path` | 是 | 源 APK |
| `output_dir` | 是 | 解包目录（不存在会创建） |
| `force` | 否 | 覆盖已有输出目录 |
| `frame_path` / `frame_tag` | 否 | 仅当 apktool 需要非默认 framework 时用（多数应用不需要） |

产出 apktool 工程：`smali*/`、`res/`、`AndroidManifest.xml`、`assets/`、`resources.arsc`。
**这是唯一能回编译的产物。**

### apk_reverse_jadx
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_apk_path` | 是 | 源 APK |
| `output_dir` | 是 | 输出目录 |
| `deobf` | 否 | 开启反混淆重命名，便于阅读 |
| `show_inconsistent_code` | 否 | 反编译出错处显示不完整代码（排查"为什么这段读不出来"时开） |

只用于阅读，**不要在这里改文件**。按需使用：先 search_text 定位，命中读不出 Java 语义才开，读完即删。

### apk_reverse_search_text
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_path` | 是 | 解包目录、jadx 输出目录，或直接传 APK 路径（内部建临时工作区） |
| `query` | 是 | 关键词或正则 |
| `scope` | 否 | `manifest` / `res` / `smali` / `jadx` / `native_strings` / `all`（默认倾向 all） |
| `regex` | 否 | 按正则解释 `query` |
| `case_insensitive` | 否 | 忽略大小写 |
| `max_results` | 否 | 限制返回条数，避免刷屏 |

### apk_reverse_search_address
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_path` | 是 | 同上 |
| `query` | 是 | 资源 ID（如 `0x7f0b01a2`）、引用名、native 符号、偏移或 hex 模式 |
| `scope` | 否 | `resource_id` / `smali_ref` / `jadx_ref` / `native_symbol` / `native_offset` / `hex_bytes` / `all` |
| `max_results` | 否 | 同上 |

用途是回答「这个资源/字符串被谁引用」——比在 smali 树里逐文件 grep 快一个数量级。

### apk_reverse_build
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `decoded_dir` | 是 | apktool 工程目录（就是 `decode` 的 `output_dir`） |
| `output_apk_path` | 是 | 未签名 APK 输出路径 |
| `frame_path` / `frame_tag` | 否 | 同 decode |

### apk_reverse_sign
| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `input_apk_path` | 是 | 待签名 APK（通常是 build 的产物） |
| `output_apk_path` | 是 | 已签名 APK 输出路径 |
| `sign_mode` | 是 | `debug` 或 `keystore` |
| `keystore_path` / `storepass` / `alias` / `keypass` | keystore 模式必填（前三个） | 密钥库信息 |

用的是 apksig API（v2/v3 签名），不需要额外装 `apksigner` / `zipalign`。

### apk_reverse_build_and_sign
参数 = `build` 的参数 + `sign` 的 `sign_mode` 与 keystore 相关字段（没有 `input_apk_path`）。
| 参数 | 必填 |
| --- | --- |
| `decoded_dir`、`output_apk_path`、`sign_mode` | 是 |
| `keystore_path`、`storepass`、`alias`、`keypass` | keystore 模式 |
| `frame_path`、`frame_tag` | 否 |

## 推荐调用顺序（路线 B 标准链）

1. `inspect` → 记下包名/版本/是否 split/有无 so
2. `decode` → `decoded/`
3. `jadx`（可 `deobf`）→ `jadx_out/`
4. `search_text` / `search_address` 反复收缩到具体文件
5. 改 `decoded/` 里的文件（不用工具，直接文件读写）
6. build：**只能在 proot 里跑**，命令见文末「回编译为什么只能在 proot」
7. sign：回 App 内用 `apk_reverse_sign`
8. 装到设备验证（见 SKILL.md ⑦ 装机验证六项）

## 工作区布局（别往 /sdcard 解包）

实测同一个 7MB APK：decode 到 App 私有 f2fs 目录 24.8 秒，到 `/sdcard` 115 秒（4.6 倍）。
统一用 `apkw.sh new` 建工作区（`<hash>` = 源 APK 的 sha256 前 8 位）。本例中 `<xxx>` 是占位符、`<` 是重定向符，**必须换成实际值**再执行。

```
/data/data/com.ai.assistance.operit/files/apkwork/<hash>/
├── decoded/
├── jadx_out/
├── patched.apk
└── notes.md      ← 记录改了哪一层、哪一行（下次接手/回滚靠它）
```

## 本机能力边界（现在不做的事）

| 做不到 | 替代做法 |
| --- | --- |
| native `.so` 反编译成 C 伪代码 | 只在 smali 层 stub 掉调用，或说明"逻辑在 native，需另装 IDA/radare2" |
| Flutter(Dart) / Unity(il2cpp) 结构化改造 | 只做 `lib/` 与 `assets/` 层面的可读性排查，不当成 Java 层硬改 |
| split APK 合并成单一 APK | 逐个 decode `base.apk` 与对应 `config.*.apk`，改动落在 base |
| 动态 Hook（Frida） | 可选加装 `frida-server`（arm64）+ `frida-tools`；未装时不要承诺动态验证 |
| 绕过服务端下发的权限/价格 | 客户端改不动，直接给结论 |

## 可选加装（非必需，按任务再谈）

- `frida-server`（arm64）+ `frida-tools`：动态观察参数返回值，比重打包快得多，适合"先确认逻辑再决定改哪"。
- radare2 / IDA：`lib/*.so` 承载核心逻辑时才需要。
- 自己的 keystore：需要长期升级同一套改包时，用固定 keystore 生成一次，之后 `sign_mode=keystore` 复用。

## 回编译为什么只能在 proot（实测）

`apk_reverse_build` / `apk_reverse_build_and_sign` 内部用 ProcessBuilder 执行 apktool 解压出的
`cache/aapt2_*.tmp`。Operit 进程的 SELinux 域是 `untrusted_app`，Android 不允许它执行自己数据目录里
的可执行文件，所以必然报 `java.io.IOException: error=13, Permission denied`。签名反而能在 App 内做：
apksig 是纯 Java，不 exec 外部程序。

正确做法（在 super_admin:terminal 的 Ubuntu 环境里跑）：

```sh
H=d2cb5da8    # = apkw.sh new 回显的目录名（源包 sha256 前 8 位）
D=/data/data/com.ai.assistance.operit/files/apkwork/$H/decoded
java -jar /root/tools/apktool.jar b "$D" -o /root/tools/out/out.apk \
     --aapt /root/tools/sdk/build-tools/aapt2
```

- `--aapt` 必须显式给：apktool 3.0.1 默认解压自带的 x86_64 aapt2，在 arm64 上直接 `exit code = 132`（SIGILL）。
- proot 可以直接读写私有工作区，build 也吃 f2fs 速度，不用把 130MB 拷到 /sdcard。
- 产物落在 `/root/tools/out/`（proot 镜像内，App 看不到），签名或安装前必须 `cp` 到 `/sdcard/...`。
- 签名：`apk_reverse_sign`，debug keystore = `/data/user/0/com.ai.assistance.operit/files/pkcs12.keystore`，alias `androidkey`。

## aapt2 应急恢复（只对 App 内 build 有意义）

proot 回编译读的是 `/root/tools/sdk/build-tools/aapt2`，与 cache 无关；cache 里那份只被
`apk_reverse_build` 用，而那条路本来就走不通（见上一节）。所以发现它没了，先问一句“真的需要补吗”。

要补就按下面几行（root shell，实测输出与原文件字节一致，sha256 前 16 位 `e5b5ff7f0d4f6ecd`）：

```sh
APP=/data/data/com.ai.assistance.operit
R=$(ls $APP/files/toolpkg_cache/*apk_reverse_toolkit*/resources/apktool/apktool-runtime-android.jar | head -1)
unzip -p "$R" prebuilt/android/aapt2 > $APP/cache/aapt2_3093869806224049535741061713990895331.tmp
chown $(stat -c %u $APP):$(stat -c %g $APP) $APP/cache/aapt2_*.tmp
chmod 700 $APP/cache/aapt2_*.tmp
restorecon $APP/cache/aapt2_*.tmp
```

文件名取自 jar 内资源路径的固定 hash，不要改名；只要 `cache/aapt2_*.tmp` 存在、可执行、属主正确即可。
校验：`$APP/cache/aapt2_*.tmp version` 应输出 `Android Asset Packaging Tool (aapt) 2.19-compiler261019154356`，
大小 `4,706,040 B`。属主不是 App 的 uid/gid 时会报 `error=13`（本机为 `u0_a236`）。
