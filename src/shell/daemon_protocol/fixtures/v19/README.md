# Frozen public dialect 19

Source: v0.6.0, commit `8c83190145da83c6961ffcb379a007a4918a9d83`.
Frames are manually encoded from the tagged protocol: strict BTD1 header,
metadata with cwd but without recovery phase, single-row registry without
recovery trailer, semantic keys (three codepoints), and pixel-bearing mouse.
Snapshot is the existing v18 two-cell fixture with v19's separate text-pointer
byte and title v19. Never regenerate from current-version encoders.
The corresponding v18 request/registry frames use v0.5.0 commit
`ab73f48424d96fb53547e94f1c48ca67ee8bdf49`, which has identical input and
registry payloads. Only the v18 snapshot prefix differs.
