#!/usr/bin/env bash
# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# probe-enforced.sh — confirm the KERNEL layer of wuwei-confine! is actually live.
#
# enforced-test.lisp (golden) proves the FLOOR-level boundary portably: a weak
# guard still can't write out of the box. But the floor is a userspace check; the
# extra thing Landlock buys — closing a live TOCTOU / a path the userspace funnel
# didn't guard — can only be confirmed on a Landlock-capable kernel, so it can't
# be a portable golden. Run this by hand there to confirm the kernel engaged and
# hasn't silently regressed to floor-only.
#
# Expected on a Landlock-capable Linux kernel (>=5.13):
#   kernel-status => fully-enforced   (the kernel accepted + enforces the fence)
# On a kernel without Landlock it reads not-enforced/unsupported — the floor (and
# wuwei's safe-under? guard) still hold; that's the honest best-effort degrade.

set -u
RUSTY="${RUSTY:-rusty}"
command -v "$RUSTY" >/dev/null 2>&1 || { echo "need rusty on PATH"; exit 2; }

BOX="/tmp/wuwei-enforced-probe/"
rm -rf "$BOX"; mkdir -p "$BOX"
cd "$(dirname "$0")"

SCRIPT="$(mktemp /tmp/wuwei-enforced-XXXX.lisp)"
cat > "$SCRIPT" <<EOF
(load "wuwei.lisp")
(define st (wuwei-confine! "$BOX"))
(display (list 'kernel-status st)) (newline)
EOF

echo "== wuwei-confine! kernel status =="
STATUS="$(RUSTY_SANDBOX_DEBUG=1 "$RUSTY" "$SCRIPT" 2>&1)"
echo "$STATUS"

echo "== verdict =="
if echo "$STATUS" | grep -q "fully-enforced"; then
  echo "KERNEL LAYER LIVE: wuwei runs are Landlock-fenced on this kernel."
elif echo "$STATUS" | grep -qiE "not-enforced|unsupported"; then
  echo "FLOOR ONLY: no Landlock on this kernel — userspace floor + safe-under? still hold."
else
  echo "UNEXPECTED: no kernel-status line (regression?)."
fi

rm -f "$SCRIPT"; rm -rf "$BOX"
