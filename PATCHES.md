# Patches

This is a fork of [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
for the xiu deployment (`xiu-router`, where it is a submodule). It exists so that fixes we
need can ship before upstream merges them, and so that deeper customisation has somewhere
to live.

## The rule

> **Edit an upstream file only where upstream offers no other attachment point.
> Anything that can live outside CLIProxyAPI stays outside CLIProxyAPI.**

Upstream moves fast — dozens of merged PRs a week, and the management panel is a compiled
asset we do not build. Every upstream file we touch is a conflict we pay for on every
release. Files we add under a `xiu` namespace cost nothing, forever.

Configuration is the cheapest attachment point of all and is already used heavily:
`xiu-router` owns `deploy/cliproxy/config.enforced.yaml`, which is force-synced into the
running config on every deploy. **If a behaviour is reachable from config, it does not
belong in this fork.**

### No prose inside upstream files

The unit of conflict is the **line**, not the file, and git conflicts on context as well
as on content. Rationale lives in our own files (`xiu/`, this document). Inside an
upstream file, comments are only ever the ones the upstream PR itself would carry.

## Where our code lives

| Path | Contents |
|---|---|
| `xiu/` | Fork tooling: the touchpoint gate and the test gate, with their ledgers |
| `**/xiu_*.go` | Go code of ours, where package layout forbids `xiu/`. Exempt by basename |

Upstream will never create these paths, so they never conflict.

## The gates

Both run in `xiu-router`'s `release.sh` before an image is built, so neither can be
skipped on the way to production. Both are checked in **both directions**, because a
ledger nobody prunes stops being a record of what is true and becomes permission granted
in advance.

- **`xiu/check-touchpoints.sh`** — fails on an upstream file modified but not declared in
  `xiu/allowed-touchpoints.txt`, and on a declared file with no diff behind it.

  Patch sets do not grow by bad decisions — they grow one justified file at a time, and no
  single addition ever looks wrong. This turns "conflict risk" into an exit code.

- **`xiu/run-tests.sh`** — runs `go test ./...` and fails on any failure not declared in
  `xiu/known-upstream-failures.txt`, and on any declared failure that now passes.

  Upstream ships red tests (three of them through `v7.2.143`). Demanding green would
  never pass; testing only the packages we touch would say nothing when we change a
  shared helper.
  The ledger is what makes the full suite usable as a gate.

  Undeclared failures get re-run **in isolation** before the verdict. Some upstream tests
  only go red under the CPU pressure of the whole suite at once, and the ledger is the
  wrong home for those — they are green most of the time, so the reverse check would
  report them "now passing" on every good run and the ledger would never settle. Still
  red alone blocks; green alone is reported and let through. A genuinely broken test
  cannot hide there, because isolation is exactly where it still fails.

## The patch set

**Empty.** No upstream file carries a change of ours right now; `PATCHES.md` is the only
entry in the touchpoint allowlist, and it is a file we added.

The one patch this fork ever carried — an HTTPS proxy handshake that offered `h2` over
ALPN and then wrote an HTTP/1.1 `CONNECT` over it, so a proxy that picked `h2` dropped the
connection with `unexpected EOF` — was filed as
[#5287](https://github.com/router-for-me/CLIProxyAPI/issues/5287) /
[#5288](https://github.com/router-for-me/CLIProxyAPI/pull/5288) and landed upstream in
`v7.2.145` (`8dd78042`). It came back as upstream's own code, so it left on the rebase.

Two pieces of ours did not come back, both deliberately dropped rather than re-applied:

- The dial hook read its TLS and dial settings from the transport *at dial time*;
  upstream's captures them when the transport is built. Nothing in this tree changes
  either field after `BuildHTTPTransport` returns, so the difference is unobservable —
  and it is what made the second piece necessary.
- `antigravity_executor.go` shaped a freshly built transport in place instead of cloning
  it, because a clone kept consulting the original through the hook. Upstream's hook reads
  nothing from the transport, so the clone is harmless there.

A one-minute bound on the `CONNECT` exchange in `httpConnectDialer`, which upstream still
lacks, went with them. It was written when this fork's `BuildHTTPTransport` routed through
that dialer and had to restore the guards net/http provides; the fix later shrank to the
ALPN alone and left the bound behind as an improvement to upstream's own code — which is
an upstream PR, not a patch we carry.

## Syncing with upstream

Same discipline as the `new-api` fork, and for the same two reasons:

```bash
git fetch upstream --tags
git rebase --onto <new tag> <old tag>     # one tag at a time, never merge
git reset --soft <new tag> && git commit  # squash back to a single commit
bash xiu/check-touchpoints.sh
git push --force-with-lease
```

- **Never merge.** A merge commit buries the patch set in upstream history, and the only
  thing keeping the conflict cost of this fork visible is that `git show xiu` *is* the
  patch set.
- **Squash back to one commit.** The other half of the same constraint: a patch set spread
  over several commits has to be replayed — and re-conflicted — commit by commit.

When the upstream PR merges, the rebase will drop the patch on its own and the gate will
then fail on a stale allowlist entry. That failure is the reminder to delete this row.
