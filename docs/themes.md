# Reader themes

Choose a style from the **Theme** menu. Use the sun/moon toolbar button to switch between its light and dark palettes.
Selecting a style sets its default font size. The font buttons can then adjust or reset that size.
Enable **Settings → Save settings across sessions** to keep the chosen theme, mode, and font size.

| Theme | Character | Default font setting |
| --- | --- | ---: |
| Classic | Neutral white or charcoal with blue links | 12 |
| Paper | Warm parchment with brown and amber accents | 14 |
| Terminal | Compact green-tinted surfaces | 11 |
| Nord | Cool slate, pale snow, and frost-blue accents | 13 |
| Solarized | Cream and teal in light mode; deep teal in dark mode | 14 |
| Gruvbox | Warm retro colors, cream text, and earthy accents | 12 |
| Catppuccin | Soft lavender accents with Latte- and Mocha-inspired surfaces | 13 |

Each palette covers the document, code and quote panels, toolbar, menus, sidebars, links, selections, highlights, and alert labels.
Active toolbar buttons retain MDF's blue indicator, including the selected no-wrap button.
Highlights use dark amber surfaces in dark mode so their text stays readable.
The existing Open Sans fast path and deferred monospace loading apply to every theme.

## References and approach

The online review used these primary sources:

- [Typora's theme gallery](https://theme.typora.io/) shows document-focused styles across reading and editing use cases.
- [Zed's theme documentation](https://zed.dev/docs/themes) describes selectable themes, previews, saved preferences, and separate light/dark choices.
- [Obsidian's appearance documentation](https://obsidian.md/help/appearance) separates light/dark color schemes from custom themes.
- [Nord's palette guidelines](https://www.nordtheme.com/docs/colors-and-palettes/) assign related colors to backgrounds, panels, text, selections, and accents.
- [Solarized](https://ethanschoonover.com/solarized/) provides paired light/dark palettes and a restrained set of accent colors.
- [Gruvbox](https://github.com/morhetz/gruvbox) uses distinguishable retro colors with light/dark variants.
- [Catppuccin's palette](https://catppuccin.com/palette/) defines a light Latte variant and darker flavors, including Mocha.

These MDF adaptations keep native controls and the existing font-loading policy.
Some accent and muted colors are adjusted for readable text on the actual MDF surfaces.
Theme data is compiled into Zig; choosing a theme needs no stylesheet parser, downloaded assets, or additional font discovery.

## Implementation and checks

`src/themes.zig` owns the palette catalog, names, stable IDs, and default sizes.
The original Classic, Paper, and Terminal IDs keep their numeric order and stored JSON names.
The private C API exposes borrowed catalog metadata and RGB records to FLTK and the experimental native renderer.
Both menus derive their choices from that catalog, so a saved theme and its menu entry use the same definition.

Core tests cover every theme's saved-preference round trip, C record layout, catalog lookup, default sizes, and contrast.
Body text, links, muted text, and alert labels meet a 4.5:1 contrast threshold on the reader and panel surfaces.
Selected and highlighted body text use the same minimum threshold.
The GUI suite switches every theme in both modes, checks the document and toolbar colors, and saves preview images.
