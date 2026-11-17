# Golden wire streams

Sessions outlive app updates: a new Tecolot must read what an older
`tecolot-sessiond` writes. Each directory holds bytes that one release wrote.
`GoldenStreamTests` decodes them with the current code.

- `messages.bin`: one envelope for each message kind, in the order of
  `GoldenRelease<N>.messages`.
- `session.bin`: everything a helper wrote to its client during a scripted
  session.
- `session-screen.txt`: the screen that a client shows after `session.bin`.

Rules:

1. Never change the files of a release, and never change its samples in
   `GoldenStreamTests.swift`. A test that fails here means that the new code
   cannot read an old helper.
2. When a release changes the wire format, record a new directory:
   `TECOLOT_RECORD_GOLDEN=release-<N> swift test --filter GoldenStreamTests/record`,
   then add `GoldenRelease<N>` and its tests.
