# 未镜像的上游档（按需取用）

本技能只做**审查**，因此没有落地上游的「生成向」文件。它们仍可用，但需要联网：

| 上游文件 | 干什么用 | 什么时候才需要 |
|---|---|---|
| `01-starting-from-scratch.md` | 从零设计一个新页面的顺序 | 用户问「帮我设计一个界面」——超出本技能范围 |
| `10-tailwind-mapping.md` | 规则 → Tailwind 类的映射表 | **确认项目确实用 Tailwind** 时，用来说明改法的具体类名 |
| `11-design-tokens.md` | 色板算法、字号/间距阶的生成流程 | 用户要「建一套设计规范」时 |
| `12-component-recipes.md` | 按钮/表单/卡片等组件的标准做法 | 用户要给具体组件定样式时 |
| `16-component-libraries.md` | shadcn/MUI/Ant 的 token 契约 | 项目用了这些库，且要改动组件 |

取用方式（锁定同一提交，避免与本文档版本错位）：

```
https://raw.githubusercontent.com/edisonmbli/refactoring-ui-skill/4459662c4fbf36d54342b1546d8851273031442c/skills/refactoring-ui/references/<文件名>
```

例：

```
https://raw.githubusercontent.com/edisonmbli/refactoring-ui-skill/4459662c4fbf36d54342b1546d8851273031442c/skills/refactoring-ui/references/11-design-tokens.md
```

用法边界（很重要）：

- 取来之后 **仍然只用于审查**：可以引用它的规则号解释「为什么这里不对」，但不要照它去生成一套 token 塞进用户项目。
- 若用户明确要「顺便把这套规范落地」，那是另一个任务，需要用户确认后再做——本技能默认不越界。

## 其他上游资源

- 仓库根 `ATTRIBUTION.md`：原书版权归属与非官方声明（已镜像到本技能根目录）。
- 仓库根 `LICENSE`：MIT 全文，**未镜像**；如需分发请注意保留原仓库的许可声明，本技能已在 `ATTRIBUTION.md` 与本文件中标注来源。
- `scripts/generate_palette.py`、`eval/`、`templates/`：与本技能的审查定位无关，未镜像。