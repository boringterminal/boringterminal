# Attach dialect 10

Frozen from public release `v0.3.0`, commit
`487291eee31f26454df8fa00724e3a6ede726514`.

The hex fixtures are complete `BTD1` frames, including headers. Tests send and
compare these bytes directly; they must not be regenerated through the current
protocol codec. Replace this directory only through the compatibility-window
rotation in RFC 0019.
