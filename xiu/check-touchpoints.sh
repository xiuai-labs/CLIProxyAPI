#!/usr/bin/env bash
#
# Fail when this fork modifies upstream files that are not declared in allowed-touchpoints.txt.
#
# Patch sets do not grow by bad decisions — they grow one justified file at a time, and no
# single addition ever looks wrong. This turns "conflict risk" from a feeling into an exit code.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The newest upstream tag reachable from HEAD. We rebase onto that tag, so it stays an
# ancestor and this resolves itself — no pinned version to go stale.
upstream_tag="${UPSTREAM_TAG:-$(git describe --tags --abbrev=0 --match 'v*')}"

if ! git rev-parse --verify --quiet "${upstream_tag}^{commit}" >/dev/null; then
  echo "error: upstream tag '${upstream_tag}' not found. Fetch tags with --fetch-depth 0." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Three-dot: diff against the merge base, so upstream commits we have not merged yet are
# not counted as our changes.
git diff --name-only "${upstream_tag}...HEAD" >"$work/raw"

# Our own namespaces are exempt by construction: upstream will never create `xiu/`,
# nor a file whose basename starts with `xiu_`.
#
# The basename rule exists for Go: its package layout forbids putting our code under
# `xiu/` — a middleware has to live in `middleware/`, its config in `common/`. Listing
# such files in the allowlist instead would fill it with entries that carry no merge risk
# at all (upstream cannot conflict with a file it does not have), burying the entries that
# do. The allowlist is for **edits to upstream's own files**; that is what costs us.
#
# `|| true` because grep exits 1 on an empty result, which is the good case here.
LC_ALL=C sort "$work/raw" \
  | grep -vE '^xiu/' \
  | grep -vE '(^|/)xiu_[^/]*$' >"$work/touched" || true

grep -vE '^[[:space:]]*(#|$)' xiu/allowed-touchpoints.txt | LC_ALL=C sort >"$work/allowed"

status=0

undeclared="$(LC_ALL=C comm -23 "$work/touched" "$work/allowed")"
if [ -n "$undeclared" ]; then
  echo "Undeclared upstream touchpoints (base: ${upstream_tag}):" >&2
  printf '  %s\n' $undeclared >&2
  echo >&2
  echo "Either move the change into xiu/ (or a xiu_* file), or declare it in" >&2
  echo "xiu/allowed-touchpoints.txt AND add a row to PATCHES.md explaining why it must" >&2
  echo "live inside an upstream file." >&2
  status=1
fi

# The reverse direction matters just as much. A one-way check turns the allowlist into
# permission granted in advance: entries get added for changes someone intends to make,
# and then the gate reads "you already have permission" instead of "justify this the
# moment you make it". Same double-entry idea as reconciling ledgers in both directions.
stale="$(LC_ALL=C comm -13 "$work/touched" "$work/allowed")"
if [ -n "$stale" ]; then
  echo >&2
  echo "Declared but unmodified (base: ${upstream_tag}):" >&2
  printf '  %s\n' $stale >&2
  echo >&2
  echo "Remove these from xiu/allowed-touchpoints.txt. Declare a file when the change" >&2
  echo "lands, not before — an allowlist entry with no diff behind it is a standing" >&2
  echo "permission nobody reviewed." >&2
  status=1
fi

[ "$status" -eq 0 ] || exit "$status"

touched_count="$(wc -l <"$work/touched" | tr -d ' ')"
echo "OK: ${touched_count} upstream file(s) touched, all declared (base: ${upstream_tag})."
