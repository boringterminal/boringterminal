# Real-application byte fixtures

Captured and reduced terminal streams live here. A `.hex` file is ASCII
hexadecimal representing the exact bytes, so it remains reviewable in git and
can be replayed with `xxd -r -p FILE` before passing the result to `vtdiff`.

Each behavior also needs an automated assertion until the corpus runner learns
to compare action logs as well as final grid text.

Semantic keyboard-event fixtures that cannot be expressed as child-to-terminal
byte replay live in `tests/kitty-keyboard/`. A keyboard bug joins both corpora
only when it also has a minimized child-output stream with stable final VT
state or actions.

- `codex-startup-color-queries.hex` — reduced OSC 10/11 startup probe.
- `codex-rounded-box.hex` — reduced Codex panel using the light/rounded box
  connectors that must rasterize continuously across cell boundaries.
- `codex-mixed-intensity-border.hex` — reduced Codex border rows showing that
  its `NO_COLOR` rendering path uses `CSI ; m` to reset an earlier SGR 2
  before the closing border. The resulting normal-intensity segment is
  application-authored and remains a useful SGR oracle, but it is not the
  normal colored Codex appearance.
- `codex-sparkle-width.hex` — the UTF-8 `✨` at the start of Codex's update
  row; it must occupy two cells so the closing box rule stays aligned.
