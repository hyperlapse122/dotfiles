# Antigravity sidecar

This package provides a loopback-only proxy for omp's Antigravity provider.
It forwards the pinned Cloud Code Assist paths to
`https://daily-cloudcode-pa.googleapis.com` and rewrites only
`request.systemInstruction.parts[].text` values.

The proxy keeps the upstream response status and body stream. It removes
hop-by-hop and stale body headers, rejects unknown paths, bounds request bodies,
and never logs request bodies or credentials.

The transformation patterns follow
[bottlebrushes/antigravity-masking-sidecar](https://github.com/bottlebrushes/antigravity-masking-sidecar),
used under its MIT license in `LICENSE.antigravity-masking-sidecar`.
