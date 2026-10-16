# Markdown, ready to read.

A small native viewer for **clear writing**, *focused reading*, and `fast startup`.

## Core Markdown

Text wraps to the window. Select words in a paragraph and press **Ctrl+C** to copy them.
Accents work too: ação, café, naïve, über. Entities: &amp; &copy; &#x2192;.

- A plain list item
- An item with **emphasis**
  - A nested item
  - Another nested item

3. An ordered item
4. The next item

> A quotation has room to breathe.
>
> Save this file in an editor to see automatic reload.

## Code

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, Markdown!\n", .{});
}
```

---

Open the [project README](../../README.md), visit [Zig](https://ziglang.org), or jump to [Code](#code).

HTML keeps its formatting: <em>emphasized HTML</em>. A missing image shows its description: ![A small mountain](mountain.png).
