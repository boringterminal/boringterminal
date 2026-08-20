# Attach dialect 13

Frozen from public release `v0.4.0`, commit
`2b5c358857bd4043efeaaf2e71f8cd33ed6a31c7`.

The hex fixtures are complete `BTD1` frames, including headers. Tests send and
compare these bytes directly; they must not be regenerated through the current
protocol codec. Replace this directory only through the compatibility-window
rotation in RFC 0019.
