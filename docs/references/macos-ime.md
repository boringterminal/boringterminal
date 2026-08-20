# NSTextInputClient and macOS input — field notes

The difference between "mac native" and "Alacritty feel" lives in this
protocol. It is badly documented; these notes + Ghostty's implementation
(`macos/Sources/Ghostty/` — the NSView surface implements NSTextInputClient
in Swift) are the working references. Budget two careful weeks (RFC 0005).

## The flow

1. `keyDown:` arrives at our NSView. **Always** hand it to
   `interpretKeyEvents:@[event]` first — never pre-filter "simple" keys;
   the input context is a state machine (dead keys!) and must see everything.
2. The text system calls back while that transaction is active:
   - `insertText:replacementRange:` — accumulate committed text in callback
     order; correlate it with the original native event after
     `interpretKeyEvents:` returns, then encode through the daemon-owned
     keyboard mode.
     ⚠️ argument may be NSString *or* NSAttributedString; handle both.
   - `setMarkedText:selectedRange:replacementRange:` — pre-edit text
     (IME composition, dead-key state) → render inline at cursor with
     underline; **never** write marked text to the PTY or the grid.
   - `unmarkText` / marked-text cleared → drop the overlay.
   - `doCommandBySelector:` — the text system didn't consume it
     (`insertNewline:`, `deleteBackward:`, `cancelOperation:`, arrows...).
     **Do not call super / NSBeep.** The callback only records that outcome;
     map the *original event* (keep it around during `interpretKeyEvents`) to
     the semantic key after AppKit returns.
3. Keys with ⌘ generally shouldn't reach `interpretKeyEvents:` — route to
   app shortcuts before step 1. ⌃ keys mostly fall through to
   doCommandBySelector or need direct handling (⌃C etc. — encode from the
   event; the text system does nothing useful with them).

## Protocol methods you must implement honestly

- `hasMarkedText`, `markedRange`, `selectedRange` — IMEs query these
  constantly; lying breaks Japanese reconversion. A terminal has no real
  "selected range" for the text system: report the marked range or
  `{NSNotFound, 0}` consistently (see how Ghostty answers).
- `firstRectForCharacterRange:actualRange:` — **positions the IME candidate
  window.** Return the screen rect of the cursor cell (convert view→window→
  screen coords; wrong space = candidate window in a corner — the classic
  bug).
- `attributedSubstringForProposedRange:` — return marked text if asked;
  nil otherwise is acceptable in practice.
- `characterIndexForPoint:` — 0/NSNotFound is acceptable in practice.
- `validAttributesForMarkedText` — return `@[]` unless we render IME
  clause segmentation (underline thickness per clause — nice-to-have).

## Gotchas collected from prior art

- **Dead keys are marked text too**: ⌥e produces marked "´"; next key
  commits "é" via insertText. If you shortcut dead keys around the marked
  text path, accents break.
- **Korean IME** commits per-jamo-boundary and *re-marks*; you'll see
  insertText + setMarkedText in one event's callbacks. Order matters; write
  committed text before rendering new marked state.
- An arrow can commit preedit and still be a terminal navigation key. Replay
  Up/Down/Right after the committed text, and modified Left; do not replay
  plain Left because AppKit's Korean input path already leaves the caret in
  place. Ghostty's MIT-licensed AppKit implementation is the behavioral
  reference for this exception.
- A lone C0 character surfaced while composition is active belongs to the
  input method command path. Suppress it instead of leaking Backspace/Escape
  into the foreground program.
- **Press-and-hold** (accent popover) works iff insertText's
  `replacementRange` is respected — for a terminal, a non-empty replacement
  range means "replace previously committed char": send backspace(s) then
  the new text (this is what makes the popover *replace* `e` with `é`).
- **`performKeyEquivalent:`** fires before keyDown for ⌘-combos — claim app
  shortcuts here or the menu eats/duplicates them.
- **flagsChanged:** is separate — needed only for kitty-protocol modifier
  event reporting (flags ≥ 2); ignore otherwise.
- **Secure Keyboard Entry**: `EnableSecureEventInput()` must be paired with
  Disable *reliably* (balance on deactivate/terminate) or the whole login
  session's keyboard breaks for other apps — a notorious iTerm bug class.
- Function/media keys arrive with `NSEventModifierFlagFunction`; don't
  encode fn itself.
- `charactersIgnoringModifiers` vs `characters`: for control-key encoding
  use the base key + our own modifier table (kitty spec has the canonical
  layout-independent story; follow it for both lanes).

## Manual test checklist (run per release; no automation pretense)

- [ ] Japanese (Hiragana): type こんにちは, convert via space, candidate
      window appears at cursor, Enter commits; Esc cancels cleanly
- [ ] Chinese (Pinyin): nihao → 你好; numbered candidate selection
- [ ] Korean (2-Set): 한글 syllable composition commits correctly, backspace
      decomposes per jamo (IME handles it — verify we don't double-delete)
- [ ] ⌥e e → é; ⌥u u → ü; ⌥n n → ñ (US layout)
- [ ] Press-and-hold e → popover → select é (replaces, doesn't append)
- [ ] ⌃⌘Space emoji picker inserts at cursor (wide cell, correct width)
- [ ] vim in the terminal: Esc during Japanese composition doesn't leak to
      vim; committed text arrives as one paste-like burst not per-char
      (bracketed paste NOT involved — just ordering)
- [ ] German layout: dead ´ + e; ⌥8 → { reaches shell (option-as-option)
- [ ] Option-as-meta config on: ⌥b → ESC b; emoji/dead keys via other side
- [ ] Caps Lock + input source switch (⌃Space) cause no stuck state
- [ ] Secure Keyboard Entry on/off: IME still works; other apps unaffected
      after quit
