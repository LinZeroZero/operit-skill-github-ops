# KernelSU / APatch WebUI（单文件 HTML + JS）

审 `webroot/` 下的 `index.html` 或同类前端时读这份。这类页面的特征是：**没有构建链、没有后端、直接以 root 执行命令**。所以安全与错误的重量级，和普通网页完全不同。

## 1. 先确认宿主与注入对象

WebUI 由管理器（KernelSU / APatch 等）注入脚本后打开，页面里能用的 `ksu` 对象**不是标准的**，且不同管理器、不同版本的字段不同。审查时先抓这三件事：

- 有没有 `typeof ksu === 'undefined'` 的保护？没有的话，页面在普通浏览器里一打开就抛错、后续所有逻辑死掉（🔴 若这是主要交互路径）。
- `ksu.exec` 的返回值形态：新版是对象（含 `errno` / `stdout` / `stderr`），老版可能是字符串。代码若写死 `r.stdout`，在老宿主上得到 `undefined`——**看起来像「命令无输出」，实际是取值取错了**。判定：看代码是否对两种形态都处理。
- 有没有 `ksu.toast` 之类可选 API 的存在性判断（`typeof ksu.toast === 'function'`）。缺了在部分宿主上直接抛异常，而异常点在成功路径上。

## 2. 致命项：命令注入

页面能执行 root 命令，任何把「外部可控字符串」拼进命令行的写法都是 🔴。

判定方法：对每一处 `ksu.exec(...)`，问「这个字符串里有没有任何部分来自 `input`、`location`、`localStorage`、用户可改的文件、或上一个命令的输出？」

```js
// 🔴 用户输入直接进 shell
ksu.exec('sh /data/adb/modules/x/apply.sh ' + document.getElementById('arg').value);

// ✅ 白名单 + 引号 + 拒绝含 shell 元字符
const arg = document.getElementById('arg').value;
if (!/^[a-z0-9_-]{1,32}$/.test(arg)) throw new Error('bad arg');
ksu.exec(`sh /data/adb/modules/x/apply.sh '${arg}'`);
```

即使输入来自「自己写死的常量」，只要它经过 `localStorage` 或 URL 参数绕了一圈，就回到了不可信状态。

## 3. 第二致命项：`innerHTML` 装命令输出

命令输出可能包含 `<`、`&`、甚至 `<script>`（比如 `cat` 一个用户可写的配置文件）。用 `innerHTML` 展示输出 = 自造 XSS，而且是在一个能执行 root 命令的页面里。

- `innerHTML` / `insertAdjacentHTML` 装载**任何**命令输出或文件名 → 🔴
- 只有 `textContent` / `innerText` 是安全的；富文本展示要先转义
- 反向问题：用 `textContent` 展示需要换行的内容时，靠 `white-space: pre-wrap` 而不是 `<br>`——这属于样式，不是安全问题

## 4. 错误处理：执行了 ≠ 成功

抓三类「假成功」：

1. **只看 `stdout`**：命令失败、`stderr` 有内容、`errno != 0`，但页面显示空白或「(无输出)」，用户以为成功。
2. **只用 `r.stderr || ''` 兜底**：`stdout` 为空但 `stderr` 有内容时，必须分开显示，不能合并成一段。
3. **`try/catch` 里只写 `console.log`**：页面无任何反馈，等于失败静默。

判定模板：

```js
const r = await ksu.exec(cmd);
const out = (r && r.stdout) || '';
const err = (r && r.stderr) || '';
// 宿主没返回 errno 时不能当 0——那等于把"不知道"报成"成功"
const code = (r && typeof r.errno === 'number') ? r.errno : null;
el.textContent = (out + (err ? '\n[stderr]\n' + err : '')).trim() || '(无输出)';
if (code === null) el.textContent += '\n[宿主未返回退出码，无法确认成败]';
else if (code !== 0) el.textContent += `\n[退出码 ${code}]`;
```

模板本身也遵守同一条：宁可写「无法确认」，也不要默认成功。

## 5. 交互与状态

- **长任务无反馈**：命令可能要几秒到几十秒，期间没有 loading 状态、没有禁用按钮 → 🟡（用户会连点，导致重复执行）。若命令本身不幂等，升 🔴。
- **按钮重复点击**：连点会并发执行同一个 root 命令。判定：有没有 `disabled` 或全局 in-flight 标志。
- **成功后不刷新**：状态类命令执行完，页面上的旧数值还在（用户以为没生效）。
- **没有「危险操作」区分**：恢复默认、清数据这类操作与「查看状态」用同一个按钮样式 → 至少 🟡，见 UI 审查的 §2.8。

## 6. DOM 与运行时细节

- `document.getElementById` 在脚本执行时元素是否存在？脚本在 `<head>` 里且没等 `DOMContentLoaded` → 🟡。
- 事件绑定用 `onclick` 属性还是 `addEventListener`？内联 `onclick` 会要求函数是全局的，且 CSP 严格时失效。KSU WebUI 通常没有 CSP，所以不算 bug，但要知道代价。
- 用了 `fetch` / `XMLHttpRequest` 去外部？WebUI 环境常无网络权限或被宿主拦截；有外部请求就要有失败分支。
- **`localStorage` 存不存得住**：宿主 WebView 可能每次打开都是新会话（取决于实现），不要把重要状态只存在里面。判据：把「刷新/重开页面后状态是否还在」写成一条验证步骤。

## 7. 可访问性与移动端（与 UI 审查重叠，这里只列代码层面）

- 缺 `<meta name="viewport">` → 页面按桌面宽度渲染，手机上文字小到不可点。🔴（可用性）
- 按钮高度小于约 44px、按钮之间无间距 → 🟡（手指点不中，会误触相邻按钮）
- 只用颜色区分状态（如红字=失败）→ 见 UI 审查 §5.7
- `<pre>` 装长输出时有没有 `white-space: pre-wrap` 与 `overflow` 处理，否则长行横向溢出把整页撑宽。

## 8. 自查清单

1. `ksu` 不存在时是否优雅降级？
2. `exec` 返回值的两种形态都兼容？
3. 有没有任何可控字符串进入命令行？
4. 命令输出是否只用 `textContent` 装载？
5. `stderr` 与退出码是否分开处理并在 UI 上可见？
6. 长任务是否有 loading + 防连点？
7. 危险操作是否与普通操作在视觉与确认上区分？
8. 有没有 `viewport` meta？
9. 手机宽度（320–430px）下，所有内容是否可读可点？
10. 页面重开/刷新后，用户需要的状态是否还在？

## 9. 边界

本档只审代码行为与安全。视觉层面的层级、间距、色彩问题走 `UI审查` 技能——那边有规则编号与量化取证。