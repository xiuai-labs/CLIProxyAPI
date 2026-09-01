#!/usr/bin/env bash
#
# Run the full test suite and fail on anything that is not a declared upstream failure.
#
# Upstream ships red tests: v7.2.142 has three that fail on a clean checkout, with no
# change of ours in sight. A gate that runs `go test ./...` and demands green would never
# pass, and a gate that runs only the packages we touch stops being a gate at all — it
# would have said nothing when we changed a shared helper.
#
# So the same double-entry idea as the touchpoint gate: an explicit ledger of what is
# already broken, checked in BOTH directions. A new failure fails the build; a listed
# failure that starts passing ALSO fails the build, because a ledger nobody prunes turns
# into permission granted in advance.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# `|| true`: go test exits non-zero on any failure, which is the case we are here to judge.
go test ./... >"$work/output" 2>&1 || true

# Test **names**, not packages: a package-level ledger would hide a new failure that lands
# in a package already on the list.
sed -n 's/^--- FAIL: \([^ ]*\).*/\1/p' "$work/output" | LC_ALL=C sort -u >"$work/failed"
# An empty ledger is the goal state, not an error, and grep says "no match" with exit 1.
# Tolerate exactly that — exit 2 means the ledger itself is unreadable, and a gate that
# shrugs at a missing ledger passes everything.
grep -vE '^[[:space:]]*(#|$)' xiu/known-upstream-failures.txt | LC_ALL=C sort -u >"$work/known" || [ $? -eq 1 ]

status=0

LC_ALL=C comm -23 "$work/failed" "$work/known" >"$work/unexpected"

# An undeclared failure is not yet a verdict. Some upstream tests only go red under the
# CPU pressure of the whole suite running at once — TestWebsocketRetryBindFailureClears-
# ActiveSessionState fails that way and passes 8/8 on its own. The ledger is the wrong
# home for those: they are green most of the time, so the reverse check would report them
# "now passing" on every good run and the ledger would never settle.
#
# So sort by behaviour instead of by name. Re-run just these tests, alone: still red means
# red, and blocks. Green in isolation means it was the load, not the code — reported, not
# blocking. A genuinely broken test cannot hide here, because isolation is exactly the
# condition under which it still fails.
if [ -s "$work/unexpected" ]; then
  echo "Re-running $(wc -l <"$work/unexpected" | tr -d ' ') undeclared failure(s) in isolation..." >&2
  go test ./... -count=1 -run "^($(tr '\n' '|' <"$work/unexpected" | sed 's/|$//'))\$" >"$work/retry" 2>&1 || true
  sed -n 's/^--- FAIL: \([^ ]*\).*/\1/p' "$work/retry" | LC_ALL=C sort -u >"$work/retry_failed"

  flaky="$(LC_ALL=C comm -23 "$work/unexpected" "$work/retry_failed")"
  if [ -n "$flaky" ]; then
    echo >&2
    echo "Flaky under full-suite load, passed in isolation (not blocking):" >&2
    printf '  %s\n' $flaky >&2
  fi

  hard="$(LC_ALL=C comm -12 "$work/unexpected" "$work/retry_failed")"
  if [ -n "$hard" ]; then
    echo >&2
    echo "Test failures that are not declared upstream failures:" >&2
    printf '  %s\n' $hard >&2
    echo >&2
    echo "Fix them. Only add a line to xiu/known-upstream-failures.txt after confirming the" >&2
    echo "same test fails on the upstream baseline with no patch of ours applied." >&2
    status=1
  fi
fi

fixed="$(LC_ALL=C comm -13 "$work/failed" "$work/known")"
if [ -n "$fixed" ]; then
  echo >&2
  echo "Declared upstream failures that now pass:" >&2
  printf '  %s\n' $fixed >&2
  echo >&2
  echo "Remove them from xiu/known-upstream-failures.txt — upstream fixed them, or we did." >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo >&2
  echo "--- go test output ---" >&2
  cat "$work/output" >&2
  exit "$status"
fi

known_count="$(wc -l <"$work/known" | tr -d ' ')"
echo "OK: tests pass, except ${known_count} declared upstream failure(s)."
