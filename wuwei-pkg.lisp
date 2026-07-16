;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ─────────────────────────────────────────────────────────────────────────────
;; wuwei-pkg.lisp — the package entry point (the manifest's `main`).
;;
;; Rusty's `load` resolves a relative path against the process working directory,
;; not the loading file's directory. The bare (load "wuwei.lisp") the tests use
;; only resolves from inside the wuwei directory. A package installed by pkg
;; lives at ~/.rusty/packages/wuwei and is loaded from an arbitrary cwd, so the
;; entry loads its siblings by ABSOLUTE path. The library files are byte-
;; identical either way. (Same pattern as the loop repo's loop-pkg.lisp.)
;; ─────────────────────────────────────────────────────────────────────────────

(define wuwei-pkg-dir
  (string-append (shell "printf $HOME") "/.rusty/packages/wuwei"))

(define (wuwei-pkg-load rel)
  (load (string-append wuwei-pkg-dir "/" rel)))

(wuwei-pkg-load "wuwei.lisp")    ; the gate: effect-honest boot + per-call contracts
(wuwei-pkg-load "guards.lisp")   ; reusable guards — safe-under? / host-allowed?

;; ── Self-integrity: has wuwei's OWN installed code drifted since install day? ──
;; Delegates to pkg-drift, which compares the live package tree against the lock
;; pkg wrote at install (~/.rusty/pkg-locks/wuwei.json — OUTSIDE this tree).
;; Returns pkg-drift's verdict, e.g. 'verified | (changed ((path what)...)).
;; Guarded: if Rusty's pkg.lisp isn't loaded, pkg-drift is undefined and the
;; reference raises — caught and reported rather than crashing.
;;
;; HONEST SCOPE (the same one wuwei applies to everything): this catches accident
;; and quiet local drift — a stray editor, a bad sync, a half-finished pull. It
;; is NOT a sandbox and NOT proof against a determined local attacker (who can
;; rewrite the lock as easily as the files) or a hostile publisher. For
;; provenance — "are these the bytes the publisher meant?" — use
;; (pkg-verify "wuwei" fp) with a fingerprint that reached you OUT OF BAND.
(define (wuwei-self-check)
  (try-catch (pkg-drift "wuwei")
    (e) (list 'pkg-not-loaded
              "load Rusty's pkg.lisp first to self-check installed integrity")))
