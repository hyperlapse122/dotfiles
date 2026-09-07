#!/usr/bin/env bash
# The image build's `op`: it always fails, loudly, naming its caller.
#
# A build must resolve NO 1Password reference, and there are two ways to arrange
# that. A stub that returns a placeholder makes the render succeed and bakes
# credential-shaped content into a layer, so the first real symptom is an auth
# failure at runtime that looks like a service outage. A stub that FAILS turns the
# same mistake into a build that stops and names the file. That is the whole
# design: this is a tripwire, not a fixture.
#
# It does double duty. With no OP_CONNECT_* variables set and `op vault list`
# failing here, fact_op_available resolves opAvailable=false -- so the fact that
# skips every op-resolving target and the tripwire that catches an unskipped one
# are the same mechanism, and cannot disagree.
set -euo pipefail

printf 'op-stub: refusing to resolve %q during an image build.\n' "${*:-<no args>}" >&2
printf 'op-stub: no credential may enter an image layer. A target on the container\n' >&2
printf 'op-stub: path reached 1Password at BUILD time, which means it is not gated\n' >&2
printf 'op-stub: on the opAvailable fact. Gate it, or exclude it in .chezmoiignore.\n' >&2
printf 'op-stub: see .chezmoitemplates/resolve-op-refs-json.tmpl for the seam.\n' >&2
exit 1
