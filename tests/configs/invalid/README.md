# Negative fixtures

Every file in this directory is **expected to fail** `nginx -t`.

`tests/test-with-nginx.sh` asserts exactly that: a file here that *parses* is a
test failure, not a pass. They exist so the v0.11.x config parser has hostile
input to be measured against — a parser built only against valid configs has
failure modes nobody has seen.

They are excluded from the valid-corpus count and from the near-duplicate check in
`tests/test-corpus.sh`. They are **not** excluded from shape coverage: each one
still declares a `# Shape:` and a `# Provenance:` header, each `invalid-*` id is a
required row in `SHAPES.md`, and `test-corpus.sh` checks them like any other file.
