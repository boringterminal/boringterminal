# Unicode width, graphemes, and emoji — the policy

Width bugs are the most user-visible class of terminal bug (misaligned TUIs,
cursor drift after emoji). This doc is the single source of truth for our
policy; RFC 0002/0003 enforce it.

## The three-layer problem

1. **Storage**: a cell can retain a base plus a grapheme suffix. In full
   Unicode mode (DEC 2027 set), UAX #29 extended grapheme clusters are the
   display units: one cluster = one cell (or two for wide). `e + U+0301` is
   one cell; family emoji with ZWJs is one cluster in one wide cell. In legacy
   mode, zero-width suffixes are still retained, while non-zero codepoints
   advance independently so unnegotiated applications keep their wcwidth
   column model.
2. **Width**: how many columns a cluster spans → base rule is wcwidth-style:
   UAX #11 East Asian Width `W`/`F` → 2, zero-width marks/ZWJ → 0 (they join
   the cluster), everything else → 1. Cluster width = width of its base
   (with emoji adjustments below), not the sum.
3. **Reporting/compat**: what the *application* believes. Apps position the
   cursor assuming widths; if we disagree with the app's wcwidth, screens
   corrupt. This is why **mode 2027** exists: apps that understand clustering
   opt in; legacy apps get maximally-wcwidth-compatible cursor advancement.
   The mode defaults reset and is queryable through DECRQM. See RFC 0002 for
   the exact two behaviors.

## Emoji specifics (the gnarly 10%)

- Emoji Presentation (UAX #51 `Emoji_Presentation=Yes`) → width 2.
- **VS16** (U+FE0F) on a default-text codepoint (e.g. ☁︎ → ☁️) forces emoji
  presentation → width *becomes* 2. This mid-stream width change is the
  classic corruption source; terminalguide has a page on how terminals
  diverge here. Follow Ghostty/mode-2027 semantics.
- VS15 (U+FE0E) forces text presentation → width 1.
- ZWJ sequences: one cluster, width 2. Skin-tone modifiers: join, width 2.
- Regional indicator pairs (flags): one cluster, width 2; an *unpaired*
  regional indicator is width 1 — pairing logic is part of clustering.

## Implementation

- **Use a Unicode data library; never hand-roll tables.** Zig options:
  **zg** (https://codeberg.org/dude_the_builder/zg — successor to ziglyph;
  grapheme iteration + width + general category) or vendor **utf8proc**.
  Ghostty generates its own compact tables in `src/unicode/` — study that
  approach if zg's table size/perf disappoints; don't start there.
- Hot path: cluster segmentation runs on `print` actions. Fast-path ASCII
  (byte < 0x80 → width 1, cluster of one, no lookup) — that's ~99% of real
  terminal traffic; the Unicode machinery must cost nothing when unused.
- Unicode is pinned to **16.0.0** through **zg 0.16.2**. Width answers change
  across Unicode versions; dependency bumps must update this record and the
  width fixture table in the same change.
- wcwidth(3) on macOS is stale — never call libc wcwidth; it's the bug, not
  the oracle.

## Tests

- Fixture table: char/cluster → expected width, covering: CJK, combining
  marks, VS15/VS16 pairs, ZWJ families, flags, unpaired regional indicator,
  zero-width space vs ZWJ, Hangul jamo composition.
- Round-trip: type/paste cluster → occupies N cells → cursor at expected
  col → CPR (DSR 6) agrees → DECRQCRA checksum agrees.
- Cross-check a sample against Ghostty's behavior empirically when adding
  anything to the fixture table.

Pinned fixture table (Unicode 16.0.0):

| Input | Legacy width | Mode 2027 width | Storage in mode 2027 |
|---|---:|---:|---|
| `e` + U+0301 | 1 | 1 | one narrow cluster |
| `❤` + VS16 | 1 | 2 | one wide cluster |
| `⚡` + VS15 | 2 | 1 | one narrow cluster |
| `🧑` + ZWJ + `🌾` | 4 | 2 | one wide cluster |
| `🇮` | 1 | 1 | one narrow cluster |
| `🇮🇳` | 2 | 2 | one wide cluster |
| `✨` | 2 | 2 | one wide scalar cell |

The VT tests feed every sequence whole and byte-at-a-time, then cover cursor
position, exact copy/dump bytes, pending-wrap width changes, reflow, arena
compaction, the 64-codepoint resource cap, and the mode's DECRQM replies.

The first real-workflow regression is Codex's `✨` (`U+2728`) update banner:
zg reports it as two cells. Treating it as one shifts the row's closing box
rule one column left even though the box-drawing glyph itself is correct. The
reduced UTF-8 fixture is `tests/corpus/codex-sparkle-width.hex`.
