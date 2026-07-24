# Negative fixtures

Every file in this directory is **expected to fail** `nginx -t`.

`tests/test-with-nginx.sh` asserts exactly that: a file here that *parses* is a
test failure, not a pass. They exist so the v0.11.x config parser has hostile
input to be measured against — a parser built only against valid configs has
failure modes nobody has seen.

They are deliberately excluded from the valid-corpus count and from the shape
coverage assertion in `tests/test-corpus.sh`.
