# Per-template nginx test wrappers

`test-with-nginx.sh` validates every file in `nginx-optimizer-templates/` by
including it into a generated `nginx.conf` and running `nginx -t`. Its generic
wrapper tries http context, then server context, and gives up otherwise.

Some templates need directives defined elsewhere before they parse — a
`limit_req_zone`, a `map`, a `fastcgi_cache_path`. Those are not broken
templates; the generic wrapper simply cannot supply the context. Each such
template gets a file here named exactly `<template-name>.conf`, containing a
complete `nginx.conf` with the token `@INCLUDE@` where the template's `include`
directive should be placed.

A wrapper must supply ONLY the context the template requires. Do not paper over
a real defect by adding the directives the template itself should provide — the
point is to prove the template works when its documented prerequisites are met.
