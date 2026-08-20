# Kitty keyboard conformance corpus

This hermetic corpus is independently authored from the public
[Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
and Boring Terminal's RFCs. It contains no Kitty source, test code, copied test
names, or derived fixture organization. Ordinary CI never installs, downloads,
or executes Kitty.

Run it with:

```sh
zig build kitty-keyboard-conformance
```

Every JSON file is one schema-1 case with a stable, layer-prefixed ID and an
explicit provenance record. Binary input and output use lower-case hexadecimal.
The runner rejects unknown JSON fields, malformed metadata, duplicate IDs, and
unsupported dialect aliases. It exercises production APIs at five boundaries:

- `negotiation`: bytes through `vt.feed()`, with exact flags/replies;
- `encoder`: `vt.keyboard.encode()`, with exact child-visible bytes;
- `dialect`: selected v18/v13/v10 request encoding plus child-visible
  semantic/raw behavior;
- `matrix`: every flag combination, every modifier combination, every
  macOS-reachable physical/functional key and action, the legacy ASCII control
  table, and current-codec acceptance/rejection boundaries; and
- `pty`: selected-dialect output through a real raw PTY for v18, v13, and v10.

The 606-entry ratchet counts matrix members independently. Adding a native key
code, protocol flag, action, modifier, or accepted codec shape without a stable
inventory entry fails conformance instead of silently reducing coverage.

`ratchet.txt` is sorted and exact. A missing ratcheted case, an unlisted passing
case, a duplicate, or an excluded case that passes fails the run. Exclusions
require an owning RFC and reason; implementation backlog belongs in the local
ignored `LOOP.md` when present.

Reviewers must reject any case whose source cannot be stated. Public wire
constants are interoperability facts, but Kitty implementation/test structure
must never enter this directory. An optional opaque GUI comparison remains a
manual release aid and is not part of hermetic CI.
