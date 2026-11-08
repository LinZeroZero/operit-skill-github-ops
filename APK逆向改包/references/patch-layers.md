# 五类改动的定位路径与最小改法

通用前提：`decoded/` 是 apktool 产物（唯一能回编译），`jadx_out/` 只用来读。
每条改动都按「先搜 → 再读 → 最小改 → 单独验证」走。

---

## 1. 资源值（最省事，优先检查这一层）

**先搜什么**

- `apk_reverse_search_text`，`scope=res`，`query` 用资源名（如 `enable_?xxx`、`max_?count`、`is_?vip`）
- 想看有哪些可改的布尔/整数开关：直接读 `decoded/res/values/bools.xml`、`integers.xml`、`strings.xml`

**改法**

```xml
<!-- res/values/bools.xml -->
<bool name="enable_ad">false</bool>     <!-- 原 true -->
<integer name="free_trial_days">3650</integer>
<string name="default_server">https://example.com</string>
```

**必须检查**

- `res/values-zh-rCN/`、`res/values-en/` 等副本是否覆盖了默认值（同名字符串/数组会覆盖）。
- 改 `bool` 后如果行为没变，说明代码里没读这个资源，而是在 smali 里写了字面量 → 转第 2 类。
- 改 `string` 里含 URL 时，注意有的应用会对资源串做哈希校验。

**验证**：不用改 smali，直接 `build_and_sign` → 装机 → 看界面文字/行为是否变化。

---

## 2. smali：常量、默认值、分支、返回值（最常用）

### 2.1 定位

`apk_reverse_search_text`，`scope=smali`，常用正则：

| 目标 | query 示例 |
| --- | --- |
| 找读取某个设置键的地方 | `const-string .*"enable_xxx"` |
| 找带默认值的读取 | `invoke-virtual .*getBoolean` / `getInt` / `getString` |
| 找是否 VIP/付费 | `isVip|isPro|isPremium|isPurchased|isMember` |
| 找广告加载 | `loadAd|AdRequest|InterstitialAd` |
| 找版本/渠道判断 | `VERSION_NAME|channel|flavor` |
| 找签名校验 | `getPackageInfo|signatures|GET_SIGNATURES` |

先 `jadx_out` 读懂上下文（哪个类、哪个方法、被谁调），再用 `search_text scope=smali` 拿到同名
smali 文件路径，**只改那一个文件**。

### 2.2 最小改法（按风险从低到高）

**a) 改字符串常量**

```smali
const-string v1, "old.example.com"
    ↓
const-string v1, "new.example.com"
```

只改引号内容，不要动寄存器号与缩进。

**b) 方法强制返回 true / false**（最稳的开关改法）

在方法开头、`.locals`/`.registers` 声明之后、第一条指令之前插入：

```smali
.method public isVip()Z
    .locals 1                 # 必须是 ≥1；原来是 .locals 0 就改成 1
    const/4 v0, 0x1           # 0x1 = true，0x0 = false
    return v0
    ...原有指令（保留，但不执行）
.end method
```

要点：
- 返回类型必须匹配：`()Z` 用 `return v0`；`()I` 用 `const/4 v0, 0x1` + `return v0`（返回 int）；`()Ljava/lang/String;` 要 `const-string v0, "x"` + `return-object v0`。
- 插入的寄存器号必须 `< .locals 声明数`。`.locals 0` 的方法是唯一必须改声明数的情况。
- 插在前面而不是删掉整个方法体：删体会让栈/调试信息不一致，容易在个别机型上校验失败。

**c) 反转条件跳转**（适合"某个 if 挡住了功能"）

```smali
if-eqz v0, :cond_0     →     if-nez v0, :cond_0
if-eq v1, v2, :cond_0  →     if-ne v1, v2, :cond_0
if-ltz / if-gez        →     互换
```

一次只翻一处；翻完必须确认目标标签仍存在（`:cond_0` 不要连带改）。

**d) 改数值常量**

```smali
const/4 v0, 0x0     →  const/4 v0, 0x1
const/16 v0, 0x64   →  const/16 v0, 0x3e8     # 100 → 1000
```

`const/4` 只接受 -8..7 的范围，超出要换 `const/16` / `const`。

**e) 去掉一段调用（如广告初始化、统计上报）**

优先"让它不生效"而不是"删指令"：把 `invoke-*` 的目标方法体改成直接 `return-void`，
或者把传入的参数改成空/0。直接删 `invoke` 会破坏栈平衡，是常见闪退原因。

### 2.3 SharedPreferences 的"默认值"在 smali 里

`getBoolean("key", true)` 这类调用的第二个参数是**默认值字面量**，就在 smali 里：

```smali
const/4 v1, 0x1
invoke-virtual {v0, v2, v1}, Landroid/content/SharedPreferences;->getBoolean(Ljava/lang/String;Z)Z
```

把 `const/4 v1, 0x1` 改成 `0x0` → 该键在"用户从未设置过"时默认关闭。
注意这只影响**未写过该键**的情况；已经写过的值会被第 3 类（运行期数据）覆盖。

**验证**：装机后先清应用数据（`pm clear $PKG`）再看默认值是否按预期，才能确认改的是默认值而不是旧值。

---

## 3. 运行期配置（root 直改，不重打包）

适用：只想改当前生效的值，不想动签名/包。

```
PKG=com.example.app                              # 换成目标包名
1. su -c am force-stop $PKG
2. su -c ls /data/data/$PKG/shared_prefs/
3. su -c cp /data/data/$PKG/shared_prefs/x.xml /sdcard/tmp/x.xml
4. 改 /sdcard/tmp/x.xml 里的 value（布尔写 true/false，整数写数字，字符串直接换）
5. su -c cp /sdcard/tmp/x.xml /data/data/$PKG/shared_prefs/x.xml
6. uid=$(su -c stat -c %u /data/data/$PKG)
   su -c chown $uid:$uid /data/data/$PKG/shared_prefs/x.xml
   su -c chmod 660 /data/data/$PKG/shared_prefs/x.xml
7. 启动应用，看设置页是否保持
```

要点：
- 不 `force-stop` 就改，几乎一定会被内存中的旧值回写。
- 属主/权限错 → 应用读不到，静默回默认值（不报错，看起来像"没改成功"）。
- 应用把这份配置同步到服务端/本地数据库时，值会被改回 → 这条路不通，转第 2 类改默认值 + 断同步。
- 改前先 `cp` 一份备份到 `/data/data/com.ai.assistance.operit/files/apkwork/<hash>/prefs.bak`。

---

## 4. Manifest 标识

`decoded/AndroidManifest.xml` 是明文 XML，可改：

| 属性 | 改法 | 用途 |
| --- | --- | --- |
| `android:versionName` / `versionCode` | 直接改值 | 绕过"检测到新版本"或标记改包版本 |
| `android:debuggable="true"` | `application` 上加 | 便于 logcat/调试（部分应用会自检并拒绝启动） |
| `android:usesCleartextTraffic="true"` | 加在 `application` | 抓明文 HTTP |
| `android:exported` | 改组件 | 让某组件可被外部调起 |
| `<uses-permission>` | 增删 | 去掉某些告警或不必要的权限 |

改 `debuggable` 前先确认应用没有反调试自检，否则表现为启动即退出。

---

## 5. 包名迁移（需要与原包共存时才做）

只改 `AndroidManifest.xml` 的 `package=` 是不够的，以下都要同步，缺一处就是启动崩溃或装不上：

1. `AndroidManifest.xml` 的 `package="新包名"`
2. 所有 `<provider android:authorities="旧包名.xxx">` → 新包名（authorities 全机唯一，冲突会装不上）
3. 自定义 `permission` 名（`<permission android:name="旧包名.permission.XXX">`）及其 `uses-permission`
4. `res/values/strings.xml` 里出现的包名字符串（分享、推送、统计 SDK 常用）
5. smali 里的硬编码包名：`search_text`，`query` 为旧包名（`regex` 关掉、`scope=smali`），逐个替换为字符串替换即可，注意只替换完整包名
6. `assets/` 下的 SDK 配置文件里出现的包名（如推送 `manifest` 配置）

改完 `build_and_sign`，两个包可以同时安装。**不要**用改包名的方式规避服务端按包名的白名单以外的东西
（服务端仍会认旧包名的账号体系）。

**验证**：两个包同时存在，新包能启动、能走完被改的功能，旧包不受影响。

---

## 通用收尾

无论改哪一类，都要留一条记录（写进工作区的 `notes.md`，`apkw.sh new` 已建好骨架）：

```
源包：<path>  package=<pkg> versionName=<v> 签名=<sha256 前 8 位>
改动层：资源 / smali / manifest / prefs
文件与位置：decoded/smali_classes2/.../X.smali: isVip()Z 开头插入 return true
产物：patched.apk  sha256=<...>
安装方式：卸载重装 / 改包名共存
验证：6 项中 1-5 通过，第 6 项结论=生效
```

回滚就是「用原始 APK 重装」。不必再往工作区复制一份源 APK：notes 里已记源路径与完整 sha256，复制只会白占空间。
