#!/usr/bin/env bash
# wuwei test runner — golden-file comparison, mirroring Rusty's approach.
# Requires the `rusty` interpreter on PATH (override with RUSTY=/path/to/rusty).
set -euo pipefail
cd "$(dirname "$0")"
RUSTY="${RUSTY:-rusty}"

command -v "$RUSTY" >/dev/null 2>&1 || {
  echo "error: '$RUSTY' not found. Install Rusty and put it on PATH, or set RUSTY=/path/to/rusty."
  echo "       Rusty: https://github.com/TheLakeMan/rusty"
  exit 1
}

fail=0
run_test() {  # file expected label
  if "$RUSTY" "$1" 2>&1 | diff - "$2" > /dev/null; then
    echo "✅  $3"
  else
    echo "❌  $3"
    "$RUSTY" "$1" 2>&1 | diff - "$2" | head -30
    fail=1
  fi
}

echo "Testing wuwei against $("$RUSTY" --version 2>/dev/null || echo "$RUSTY")"
run_test gate-test.lisp expected_gate.txt "gate-test.lisp (proof gate — deterministic, no LLM)"
run_test battle-test.lisp expected_battle.txt "battle-test.lisp (jailbreak challenge — 10 attacks, 0 breaches)"
run_test guards-test.lisp expected_guards.txt "guards-test.lisp (safe-under? closes the symlink escape — needs Rusty ≥0.42.0)"
run_test net-guards-test.lisp expected_net_guards.txt "net-guards-test.lisp (host-allowed? closes the userinfo escape — offline)"
run_test multi-tenant-test.lisp expected_multi_tenant.txt "multi-tenant-test.lisp (per-tenant registry + budget; the shared-spec-name leak)"

# ── Package check: wuwei is a valid, cwd-independent Rusty package ─────────────
# Copies wuwei into a throwaway $HOME/.rusty/packages/wuwei (where pkg would put
# it) and runs the probe from an UNRELATED cwd — proving the manifest is
# well-formed and the package entry (wuwei-pkg.lisp) loads gate + guards despite
# Rusty's cwd-relative `load`. No pkg.lisp, LLM, or network.
pkg_entry_check() {
  local label="package — manifest valid + entry loads from a foreign cwd"
  local repo; repo="$(pwd)"
  local th; th="$(mktemp -d "${TMPDIR:-/tmp}/wuwei-pkg-XXXXXX")"
  case "$th" in /tmp/*|"${TMPDIR%/}"/*) ;; *) echo "❌  $label (unsafe tmp: $th)"; fail=1; return;; esac
  local dest="$th/.rusty/packages/wuwei"
  mkdir -p "$dest"
  cp package.lisp wuwei-pkg.lisp wuwei.lisp guards.lisp "$dest/"

  local out; out="$(cd "$th" && HOME="$th" "$RUSTY" "$repo/wuwei-pkg-probe.lisp" 2>&1)" || true

  local ok=1
  printf '%s\n' "$out" | grep -q '^MANIFEST-OK$'         || { echo "   manifest not well-formed"; ok=0; }
  printf '%s\n' "$out" | grep -q '^PKG-ENTRY-OK$'        || { echo "   package entry did not load gate + guards"; ok=0; }
  printf '%s\n' "$out" | grep -q '^SELFCHECK-GUARDED-OK$' || { echo "   wuwei-self-check did not degrade without pkg.lisp"; ok=0; }

  rm -rf "$th"
  if [ "$ok" -eq 1 ]; then echo "✅  $label"; else echo "❌  $label"; fail=1; fi
}
pkg_entry_check

if [ "$fail" -eq 0 ]; then
  echo "🎉 ALL PASSED"
else
  echo "SOME FAILED"; exit 1
fi
