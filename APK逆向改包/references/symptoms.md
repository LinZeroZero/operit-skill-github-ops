# 症状 → 原因 → 处理 对照表

看到症状先查这里，不要凭直觉再试一次。每一行都对应明确的下一步动作。

## 构建阶段

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| build 报 exit code = 132 | 没带 --aapt，apktool 用了自带的 x86_64 aapt2，arm64 上 SIGILL | 改用 --aapt /root/tools/sdk/build-tools/aapt2 |
| build 报 error=13 Permission denied | 在 App 内调了 build/build_and_sign，App 域禁止 exec 数据目录里的 aapt2 | 改在 proot 里跑 apktool build |
| build 报 brut.androlib 解码异常 | 该 APK 资源格式与 apktool 版本不兼容；或 decoded/ 里的 XML 被改坏 | 重新 decode（force=true）再改；改 XML 时保持标签完整 |
| build 报 resource not found | 改了 res/values 里的资源，别处仍引用；或 values-xx 副本被删 | 用 search_address scope=resource_id 查引用点，一起改回 |
| build 报 Duplicate resources | 新旧同名资源残留 | 清理 res/ 下重复文件后重编 |
| build 成功但产物异常小 | 误清空了 decoded/ 某目录 | 重新 decode，只重放记录过的那一处改动 |
| sign 报 keystore / alias 错误 | storepass、alias、keypass 不匹配 | 先在 proot 里 keytool 确认别名（Android 侧没这个命令）；不确定就先用 debug 模式 |

## 安装阶段

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| INSTALL_FAILED_UPDATE_INCOMPATIBLE | 签名与原包不同（debug 模式必然如此） | 卸载重装（丢数据）或改包名共存，二选一 |
| INSTALL_FAILED_VERSION_DOWNGRADE | 新包 versionCode 低于已装版本 | 提高 versionCode，或 pm install -d |
| INSTALL_FAILED_ALREADY_EXISTS / 冲突 | 改包名时 provider authorities 或 permission 与旧包撞了 | 按 patch-layers.md 第 5 类同步改完再装 |
| INSTALL_FAILED_INVALID_APK / 解析失败 | 直接装了 build 的未签名产物 | 用 `apk_reverse_sign` 签名后再装；`build_and_sign` 在本机必然失败，别拿它重试 |
| INSTALL_FAILED_NO_MATCHING_ABIS | lib/ 被删或不匹配当前 ABI | 恢复 lib/ 目录 |
| 装上了但桌面没图标 | 改包名后 launcher 缓存 | 重启 launcher 或刷新应用列表 |

## 运行阶段

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 只改了一个无害字符串就闪退 | 该应用对重打包有完整性/签名校验，或加了壳 | 停止改功能，先判定校验：search_text 搜 signatures、getPackageInfo、加固特征；结论写明"需先处理校验" |
| 闪退且日志有 ClassNotFoundException / NoClassDefFoundError | smali 改动破坏了类结构，或删了类/方法 | 回滚该次改动；改成"方法体里加 return"而不是删方法 |
| 闪退且日志有资源相关异常（ParseException 等） | resources.arsc 或 XML 被改坏 | 重新 decode 重做改动 |
| 闪退且日志有 VerifyError / Invalid register | 寄存器号越界，或 .locals 没同步改 | 检查插入指令用的 vN 是否小于 .locals；.locals 0 的改成 1 |
| 行为没变（最高频） | ①改在 jadx_out ②该分支不在执行路径 ③值被服务端/缓存覆盖 ④改的是默认值但设备已有旧值 | 依次排查：确认改的是 decoded/；用 search_address 查调用点；logcat 看是否走到该分支；pm clear 后重测默认值 |
| 界面文案变了但功能没变 | 改的是展示字符串，真正的开关在别处 | 用该文案反查 key，再查 key 的使用点 |
| 部分界面乱码/错位 | 改 values-xx 时破坏格式，或漏了转义字符 | 恢复该 XML，改用最小字符替换 |
| 应用能起但目标功能灰掉/提示未授权 | 门槛在服务端下发，或需要先建立账号态 | 客户端改不动，直接给结论，不要继续改 |
| 改完过一会儿自己变回去 | 应用启动时从服务端/数据库回写配置 | 说明是服务端真相，转"改默认值 + 断同步"或放弃 |

## 排查顺序（固定）

1. 先确认改的是 decoded/，不是 jadx_out/。
2. 再确认这段代码在不在实际执行路径（logcat 打点或 search_address 查调用点）。
3. 再看是不是"默认值 vs 已写入值"的问题（pm clear 复测）。
4. 最后才怀疑校验/加固，并明确写出结论，不做无依据的反复重试。

## 两条止损线

- 同一形状的尝试连续失败两次 → 回到 SKILL.md 第 4 节重新判层，不要做第三个变体。
- 判定为服务端真相或加固/校验且当前工具链处理不了 → 明确说明卡点与可选方案，不要伪装成"还在试"。
