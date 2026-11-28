# Agent Runtime / 执行架构

Zivvi renders content with native macOS text. 中文、English、组合字形 é 和 Emoji 👩🏽‍💻 共用一条基线。**粗体**、*斜体*、~~删除线~~与 `inlineCode` 可以混排。[可点击的链接](https://example.invalid/docs) 与 [延迟定义的链接][guide] 都位于原文中。

## 会话与文档
### Execution lifecycle
#### Tool execution
##### Error handling
###### Additional notes

3. 起始序号为 3。条目在窄列换行后，续行应与正文起点对齐。
   - Nested item / 嵌套项
   - A second nested item with `Sources/Features/Markdown/Rendering/VeryLongFileNameWithoutAnyBreaks.swift`
4. 第二个有序条目。

   第二段分开渲染，保留松散列表的节奏。

- [x] Parse Markdown
- [ ] Verify the reading position

> 中文引用使用正文大小。
>
> > Nested quotation with `inlineCode`.
> >
> > - An item within the quote

```rust
pub trait AgentRuntime {
	fn execute(&self) -> bool;
}

// Keep this long line intact: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz
```

```unknown-language
unknown("仍可选取与复制")
```

```
无语言标记
```

| Runtime | Protocol | Latency (ms) | Notes |
| :--- | :---: | ---: | --- |
| Pi | RPC | 42 | `RuntimeProtocol` |
| ACP | Native | 18 | [very long URL](https://example.invalid/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz) |
| | | | |

| Input | Source | Validation | Rendering | Width | State |
| --- | --- | --- | --- | --- | --- |
| 会话聊天与文档预览 | OriginalMarkdownInput | BoundaryValidation | NativeTextRendering | DynamicLayoutContext | StableOutput |

![本地示意图](sample.png)

![失效图片](missing.png)

![](missing-alt.png)

---

<aside>HTML remains literal.</aside>

数学式 `x + y`，以及脚注引用 [^note]。

[^note]: 脚注定义使用可读原文回退。 此处为示例。

[guide]: https://example.invalid/guide
