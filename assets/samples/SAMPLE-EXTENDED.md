# Markdown FAST — Extended Font Coverage

This sample exercises scripts and symbols outside the bundled Latin Open Sans subset.
The viewer prepares installed fallback fonts after its first Markdown frame.
Characters without an installed font still show missing-glyph markers.

Use [SAMPLE.md](SAMPLE.md) for the regular Markdown and code-block examples,
or [SAMPLE-HUGE.md](SAMPLE-HUGE.md) for the larger Latin-only document.

## Unicode and symbols

Latin is bundled; other scripts use system font fallback.

Latin accents: ação, coração, café, naïve, über, façade, jalapeño, São Paulo.

Greek: Καλημέρα κόσμε. Α Β Γ Δ Ε Ζ Ω. α β γ δ ε ζ ω.

Cyrillic: Привет, мир. Добро пожаловать.

Arabic: مرحبًا بالعالم

Hebrew: שלום עולם

Chinese: 你好，世界。 Japanese: こんにちは世界。 Korean: 안녕하세요 세계.

Punctuation: "straight quotes", “curly quotes”, 'apostrophe', ‘single quotes’, en–dash, em—dash, and an ellipsis…

Symbols: © ® ™ § ¶ • · ° ± × ÷ ≠ ≤ ≥ ∞ √ π µ → ← ↑ ↓ ✓ ✗.

Emoji: 😀 🚀 📝 📚 🌍 ✅ ⚠️.

An HTML entity can also need fallback: `&#x2192;` renders as &#x2192;.

## Styled fallback text

**Привет, мир.** *Καλημέρα κόσμε.* ***你好，世界。***

Inline code also needs these glyphs: `Привет 中文`.
Inline code alone does not trigger monospace discovery; fenced code blocks remain in the regular sample.

Arabic and Hebrew glyphs can shape within words, but paragraph-level word ordering remains a separate layout check.

[Back to the regular sample](SAMPLE.md#unicode-and-symbols)
