/*
 * audit.js — UI 审查取数器（L1 / L2 / L3 共用同一份逻辑）
 *
 * 用法（三种环境，返回同一个 report 对象）：
 *   L1  browser 包：browser:evaluate(function = "() => " + 本文件全文)
 *       必须包一层箭头函数：evaluate 会先 eval 字符串拿到函数再交给 page.evaluate，
 *       直接给 IIFE 会执行成功但返回 undefined（踩过一次）。
 *   L3  浏览器控制台：粘贴本文件全文后回车（末尾是 IIFE，会自动执行）
 *   L2  无 DOM：require 后调用纯函数 auditContrast('#9aa0c0', '#0f1220')
 *
 * 设计约束：
 *   1. 只读，不改 DOM、不发请求。
 *   2. 不依赖框架、不依赖 Tailwind。
 *   3. **不知道就说不知道**：背景是图/渐变、颜色是新语法无法解析时，进 report.incomplete，
 *      绝不用父级背景色顶上去硬算一个数。这条对齐 axe-core 的 incompleteData：
 *      给出错误的确定值，比承认判断不了更糟。
 *   4. 只给可被反驳的数值，不给"好不好看"的判断——判断留给 SKILL.md 的规则号。
 */
(function () {
  'use strict';

  /* ---------- 纯函数区：无 DOM 也能用 ---------- */

  function parseColor(input) {
    if (!input) return null;
    var s = String(input).trim().toLowerCase();
    if (s === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
    var m = s.match(/^rgba?\(([^)]+)\)$/);
    if (m) {
      var parts = m[1].split(/[,/\s]+/).filter(function (x) { return x !== ''; });
      var r = parseFloat(parts[0]), g = parseFloat(parts[1]), b = parseFloat(parts[2]);
      var a = parts.length > 3 ? parseFloat(parts[3]) : 1;
      if ([r, g, b, a].some(function (v) { return isNaN(v); })) return null;
      return { r: r, g: g, b: b, a: a };
    }
    var hex = s.match(/^#([0-9a-f]{3,8})$/);
    if (hex) {
      var h = hex[1];
      if (h.length === 3 || h.length === 4) {
        h = h.split('').map(function (c) { return c + c; }).join('');
      }
      if (h.length === 6 || h.length === 8) {
        return {
          r: parseInt(h.slice(0, 2), 16),
          g: parseInt(h.slice(2, 4), 16),
          b: parseInt(h.slice(4, 6), 16),
          a: h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1
        };
      }
    }
    // oklch()/lab()/color() 等新语法不猜，交给调用方记为"无法判定"
    return null;
  }

  function over(fg, bg) {
    var a = fg.a == null ? 1 : fg.a;
    return {
      r: fg.r * a + bg.r * (1 - a),
      g: fg.g * a + bg.g * (1 - a),
      b: fg.b * a + bg.b * (1 - a),
      a: 1
    };
  }

  function luminance(c) {
    var f = function (v) {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }

  function auditContrast(fg, bg) {
    var f = parseColor(fg), b = parseColor(bg);
    if (!f || !b) return null;
    if (b.a < 1) b = over(b, { r: 255, g: 255, b: 255, a: 1 });
    if (f.a < 1) f = over(f, b);
    var l1 = luminance(f), l2 = luminance(b);
    var hi = Math.max(l1, l2), lo = Math.min(l1, l2);
    return Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100;
  }

  /* ---------- DOM 区：没有 document 就只交出纯函数 ---------- */

  if (typeof document === 'undefined') {
    if (typeof module !== 'undefined' && module.exports) {
      module.exports = { auditContrast: auditContrast, parseColor: parseColor };
    }
    return { mode: 'no-dom', auditContrast: auditContrast };
  }

  var notes = [];
  var MAX_LIST = 12;
  var WHITE = { r: 255, g: 255, b: 255, a: 1 };
  // 这些节点的"背景"是图，取不到像素就不能算对比度
  var GRAPHIC = /^(IMG|CANVAS|VIDEO|IFRAME|OBJECT|SVG)$/;

  // 祖先 opacity 判定缓存：没有 Map 的环境退化为逐层遍历
  var hiddenCache = (typeof Map === 'function') ? new Map() : null;

  /*
   * opacity 不继承：父级 opacity:0 时子元素的 computed opacity 仍是 1，但整棵子树都看不见。
   * 只查自身会把这种元素算成"可见文本"，刷出并不存在的对比度问题。
   * 代价说明：裸遍历会让判断从 O(n) 变成 O(n·depth)。querySelectorAll 按文档序返回，
   * 父元素必定先于子元素被访问，所以"父已判定"可直接复用，均摊回 O(1)。
   */
  function hiddenByAncestor(el) {
    var p = el.parentElement;
    if (!p) return false;
    if (!hiddenCache) {
      var q = p;
      while (q) {
        if (parseFloat(getComputedStyle(q).opacity) === 0) return true;
        q = q.parentElement;
      }
      return false;
    }
    var known = hiddenCache.get(p);
    if (known === undefined) {
      known = (parseFloat(getComputedStyle(p).opacity) === 0) || hiddenByAncestor(p);
      hiddenCache.set(p, known);
    }
    return known;
  }

  function visible(el) {
    if (el.hasAttribute('hidden')) return false;
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    if (parseFloat(cs.opacity) === 0) return false;
    if (hiddenByAncestor(el)) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function label(el) {
    var tag = el.tagName.toLowerCase();
    var id = el.id ? '#' + el.id : '';
    var cls = el.className && typeof el.className === 'string'
      ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.')
      : '';
    return tag + id + cls;
  }

  function ownText(el) {
    var out = '';
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3) out += n.nodeValue;
    }
    return out.trim();
  }

  function rgbStr(c) {
    return 'rgb(' + Math.round(c.r) + ',' + Math.round(c.g) + ',' + Math.round(c.b) + ')';
  }

  // 无法判定的项要有上限：真实页面里每个元素都可能命中，不设限会让 report 体积失控、
  // 也会把真正的少数"存疑"埋在一堆同类项里。超出时用 incompleteTruncated 标记。
  var MAX_INCOMPLETE = 20;

  function pushIncomplete(el, txt, reason) {
    if (report.incomplete.length < MAX_INCOMPLETE) {
      report.incomplete.push({ el: label(el), text: String(txt).slice(0, 24), reason: reason });
    } else {
      report.incompleteTruncated = true;
    }
  }

  /*
   * 求元素背后"真正被看见"的颜色。三种情况必须返回 reason：
   *   bgImage / bgGradient —— 背景是图，颜色取决于像素
   *   imgNode              —— 祖先里有 <img>/<canvas>/<video> 等
   *   colorParse           —— 背景色本身无法解析
   * 半透明层按"祖先在底"的顺序自下而上合成。
   */
  function bgInfo(el) {
    var node = el, semi = [], opaque = null;
    while (node && node !== document.documentElement) {
      var st = getComputedStyle(node);
      var bi = st.getPropertyValue('background-image');
      if (bi && bi !== 'none') return { reason: /gradient/i.test(bi) ? 'bgGradient' : 'bgImage' };
      if (GRAPHIC.test(node.tagName.toUpperCase())) return { reason: 'imgNode' };

      var raw = st.getPropertyValue('background-color');
      var c = parseColor(raw);
      if (c === null) {
        if (raw && raw !== 'transparent' && raw !== 'rgba(0, 0, 0, 0)') {
          return { reason: 'colorParse:' + raw.slice(0, 24) };
        }
      } else if (c.a >= 1) {
        opaque = c;
        break;
      } else if (c.a > 0) {
        semi.unshift(c);
      }
      node = node.parentElement;
    }

    var base = opaque, assumed = false;
    if (!base) {
      /*
       * 兜底只看 html 与浏览器默认画布，绝不能再读 body：
       *   不透明的 body 已在循环里 break；半透明的 body 已进 semi。
       *   这里再叠一次 body 会把同一层合成两遍——0.5 黑叠白本应是 #808080，会算成 #404040。
       * 兜底只需回答一个问题：html 与默认画布是什么颜色。
       */
      var htmlC = parseColor(getComputedStyle(document.documentElement).backgroundColor);
      if (htmlC && htmlC.a >= 1) base = htmlC;
      else if (htmlC && htmlC.a > 0) base = over(htmlC, WHITE);
      else base = WHITE;
      // 半透明祖先已收进 semi、或 html 自带颜色 → 有实色依据；两者皆无才是"假设白底"
      assumed = !(semi.length > 0 || (htmlC && htmlC.a > 0));
    }
    for (var i = 0; i < semi.length; i++) base = over(semi[i], base);
    return { color: base, assumed: assumed };
  }

  function bump(map, key, sample) {
    if (key == null || key === '') return;
    if (!map[key]) map[key] = { value: key, count: 0, sample: sample || '' };
    map[key].count++;
  }

  function sorted(map) {
    return Object.keys(map)
      .map(function (k) { return map[k]; })
      .sort(function (a, b) { return b.count - a.count; })
      .slice(0, MAX_LIST);
  }

  var report = {
    meta: {
      url: location.href,
      viewport: { w: innerWidth, h: innerHeight },
      mode: 'render',
      generatedAt: new Date().toISOString()
    },
    contrast: { checked: 0, passed: 0, failed: 0, truncated: false, failures: [] },
    typography: { sizes: [], families: [], weights: [], lineHeights: [] },
    colors: { text: [] },
    spacing: { paddings: [], margins: [], gaps: [] },
    radii: [],
    tapTargets: { under44: [] },
    measure: [],
    incomplete: [],
    incompleteTruncated: false,
    notes: notes
  };

  try {
    // body 自己的直接文本也要算，否则整页只有裸文本时会漏检
    var all = document.querySelectorAll('body, body *');
    var sizes = Object.create(null), families = Object.create(null);
    var weights = Object.create(null), lineHeights = Object.create(null);
    var textColors = Object.create(null);
    var paddings = Object.create(null), margins = Object.create(null);
    var gaps = Object.create(null), radii = Object.create(null);
    var assumedBgReported = false;
    var sizeCount = 0;

    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!visible(el)) continue;
      var cs = getComputedStyle(el);

      bump(sizes, cs.fontSize, label(el));
      bump(families, cs.fontFamily, label(el));
      bump(weights, cs.fontWeight, label(el));
      bump(lineHeights, cs.lineHeight, label(el));

      ['paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft'].forEach(function (p) {
        if (cs[p] && cs[p] !== '0px') bump(paddings, cs[p], label(el));
      });
      ['marginTop', 'marginRight', 'marginBottom', 'marginLeft'].forEach(function (m) {
        if (cs[m] && cs[m] !== '0px' && cs[m] !== 'auto') bump(margins, cs[m], label(el));
      });
      if (cs.gap && cs.gap !== 'normal' && cs.gap !== '0px') bump(gaps, cs.gap, label(el));
      // 0px 圆角是"没有圆角"，不是一档设计取值，计进去会把真正的档位淹掉
      if (cs.borderTopLeftRadius && cs.borderTopLeftRadius !== '0px') {
        bump(radii, cs.borderTopLeftRadius, label(el));
      }

      var txt = ownText(el);
      if (!txt) continue;
      if (!parseColor(cs.color)) {
        pushIncomplete(el, txt, 'fgColorParse:' + String(cs.color).slice(0, 24));
        continue;
      }
      bump(textColors, cs.color, label(el));

      var bg = bgInfo(el);
      if (bg.reason) {
        pushIncomplete(el, txt, bg.reason);
        continue;
      }
      if (bg.assumed && !assumedBgReported) {
        assumedBgReported = true;
        notes.push('页面无实色背景，对比度按白底估算（相关项应复核）');
      }

      report.contrast.checked++;
      var ratio = auditContrast(cs.color, rgbStr(bg.color));
      var fs = parseFloat(cs.fontSize) || 16;
      var fw = parseInt(cs.fontWeight, 10) || 400;
      // WCAG：>=24px，或 >=18.66px 且 bold（axe-core 用 14pt*96/72=18.66px，同一口径）
      var large = fs >= 24 || (fs >= 18.66 && fw >= 700);
      var need = large ? 3 : 4.5;
      if (ratio != null && ratio < need) {
        report.contrast.failed++;
        if (report.contrast.failures.length < MAX_LIST) {
          report.contrast.failures.push({
            el: label(el),
            text: txt.slice(0, 24),
            fg: cs.color,
            bg: rgbStr(bg.color),
            ratio: ratio,
            need: need,
            fontSize: fs
          });
        } else {
          report.contrast.truncated = true;
        }
      } else {
        report.contrast.passed++;
      }

      // 行长：扣掉上下 padding 再除行高。否则 min-height / padding 会把行数算多，
      // charsPerLine 被压小，长文本反而报"过短"——假阴性和假阳性会一起来。
      var lh = parseFloat(cs.lineHeight);
      var lhApprox = false;
      // line-height: normal 的计算值是字符串 "normal"，parseFloat 得 NaN。
      // 若在这里跳过，"没显式写行高的页面就完全不在测行长"——而多数页面正是如此。
      // 按 1.2em 估算（Chrome/Skia 对 normal 的近似），并用 approx 标记这是估算值。
      if (isNaN(lh)) { lh = fs * 1.2; lhApprox = true; }
      // 行长要用整段文本：ownText 只取直接文本节点，段落里嵌 <b>/<a>/<code> 会漏字
      // （实测 40 字的段落被当成 36 字，cpl 因此偏小）。这与对比度用 ownText 的口径不同，是故意的。
      var full = (el.textContent || '').trim();
      if (lh > 0 && full.length >= 24) {
        var padT = parseFloat(cs.paddingTop) || 0;
        var padB = parseFloat(cs.paddingBottom) || 0;
        var contentH = el.getBoundingClientRect().height - padT - padB;
        var lines = Math.max(1, Math.round(contentH / lh));
        var cpl = Math.round(full.length / lines);
        if (report.measure.length < MAX_LIST) {
          report.measure.push({
            el: label(el),
            charsPerLine: cpl,
            lines: lines,
            fontSize: fs,
            // approx=true 表示行高是估算的（line-height: normal），引用该数值时须声明
            approx: lhApprox,
            // 末行通常填不满，"字符数 / 行数"在行数少时会系统性偏低（实测 25 字折 2 行 → 12）。
            // 行数 < 3 的项只作参考，不能直接判"行长过短"。
            lowConfidence: lines < 3,
            // 45–75 字符是桌面正文的位宽标准。窄视口一行 20–30 字符是设计结果，不是缺陷：
            // 在 390px 下套这个阈值，会让每个段落都被判超标（系统性假阳性）。
            note: innerWidth < 768
              ? 'narrow-viewport(45-75 不适用)'
              : ((cpl > 90 || cpl < 30) ? 'out-of-range(45-75)' : 'ok')
          });
        }
      }
    }

    report.typography.sizes = sorted(sizes);
    report.typography.families = sorted(families);
    report.typography.weights = sorted(weights);
    report.typography.lineHeights = sorted(lineHeights);
    report.colors.text = sorted(textColors);
    report.spacing.paddings = sorted(paddings);
    report.spacing.margins = sorted(margins);
    report.spacing.gaps = sorted(gaps);
    report.radii = sorted(radii);
    sizeCount = Object.keys(sizes).length;
    // 阈值判断必须用真实档数：sorted() 会截断到 12 条，用截断后的长度会把 19 种报成 12 种
    var colorCount = Object.keys(textColors).length;
    var weightCount = Object.keys(weights).length;

    var clickable = document.querySelectorAll('button, a[href], input:not([type=hidden]), [onclick], [role=button]');
    for (var k = 0; k < clickable.length; k++) {
      var c2 = clickable[k];
      if (!visible(c2)) continue;
      var ccs = getComputedStyle(c2);
      // 正文里的行内链接不是"点击目标"，其高度由周围文字承担；
      // 报它会刷出一堆无意义 finding（axe 的 target-size 规则同样有 inline 例外）
      if (ccs.display === 'inline' && (parseFloat(ccs.paddingTop) || 0) === 0) continue;
      var r2 = c2.getBoundingClientRect();
      if (r2.height < 44 && report.tapTargets.under44.length < MAX_LIST) {
        report.tapTargets.under44.push({
          el: label(c2),
          text: (c2.textContent || '').trim().slice(0, 20),
          w: Math.round(r2.width),
          h: Math.round(r2.height)
        });
      }
    }

    if (!document.querySelector('meta[name="viewport"]')) {
      notes.push('no viewport meta: 移动端会按桌面宽度渲染（P0 候选）');
    }
    if (weightCount > 2) {
      notes.push('font-weight 用了 ' + weightCount + ' 档：检查是否超过两档（§2.2）');
    }
    if (colorCount > 3) {
      notes.push('文字色 ' + colorCount + ' 种：上限是三种（§2.2）');
    }
    if (sizeCount > 5) {
      notes.push('字号 ' + sizeCount + ' 档：一般 3–5 档（§4.1）');
    }
    if (report.incomplete.length) {
      notes.push(report.incomplete.length + ' 项无法判定（图/渐变/新颜色语法），必须写进结论的「存疑」列'
        + (report.incompleteTruncated ? '；已达上限 ' + MAX_INCOMPLETE + ' 条，实际更多' : ''));
    }
    if (document.querySelectorAll('[style]').length) {
      notes.push('存在内联 style：静态审查时难以区分"体系值"与"一次性值"');
    }
  } catch (e) {
    notes.push('取数中断: ' + (e && e.message ? e.message : String(e)));
  }

  /*
   * 结果出口：用 <script src="audit.js"> 加载后可直接读 window.__operitUiAudit。
   * 这样 L1 不必每次把整份源码粘贴进 evaluate，回归测试也不必复制源码。
   * 只在浏览器环境挂载，Node 下走 module.exports。
   */
  if (typeof window !== 'undefined') { window.__operitUiAudit = report; }

  return report;
})()