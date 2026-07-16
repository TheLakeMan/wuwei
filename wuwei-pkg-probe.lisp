;;; wuwei-pkg-probe.lisp — proves wuwei is a valid, cwd-independent package.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; run_tests.sh copies wuwei into a throwaway $HOME/.rusty/packages/wuwei and
;;; runs this from an UNRELATED working directory. It checks three things without
;;; pkg.lisp, an LLM, or the network:
;;;   MANIFEST-OK        — package.lisp reads as a well-formed manifest
;;;   PKG-ENTRY-OK       — loading the manifest's `main` brings gate + guards up
;;;                        despite cwd-relative `load`
;;;   SELFCHECK-GUARDED  — wuwei-self-check degrades (no crash) without pkg.lisp

(define pkgdir (string-append (shell "printf $HOME") "/.rusty/packages/wuwei"))

;; (1) Manifest well-formed — read exactly as pkg-read-manifest does, but without
;; needing pkg.lisp: wrap the file in (quote ...) and evaluate.
(define manifest
  (eval-string
    (string-append "(quote " (file-read (string-append pkgdir "/package.lisp")) ")")))
(define (m-get k) (let ((h (assoc k manifest))) (if h (cadr h) #f)))
(println
  (if (and (equal? "wuwei" (m-get 'name))
           (string? (m-get 'version))
           (equal? "wuwei-pkg.lisp" (m-get 'main)))
    "MANIFEST-OK" "MANIFEST-FAIL"))

;; (2) The package entry loads gate + guards from this foreign cwd.
(load (string-append pkgdir "/wuwei-pkg.lisp"))
(define fn-type (type-of (lambda (x) x)))
(println
  (try-catch
    (if (and (equal? fn-type (type-of certify-boot))   ; wuwei.lisp loaded
             (equal? fn-type (type-of safe-under?)))    ; guards.lisp loaded
      "PKG-ENTRY-OK" "PKG-ENTRY-FAIL")
    (e) "PKG-ENTRY-FAIL"))

;; (3) Self-check degrades, not crashes, outside a real pkg-install:
;;     Rusty <0.49 has no pkg.lisp loaded → 'pkg-not-loaded; Rusty ≥0.49
;;     embeds pkg.lisp, so pkg-drift runs and honestly reports this
;;     copied-not-installed package as 'no-lock. Both are graceful.
(println
  (try-catch
    (if (member (car (wuwei-self-check)) '(pkg-not-loaded no-lock))
      "SELFCHECK-GUARDED-OK" "SELFCHECK-GUARDED-FAIL")
    (e) "SELFCHECK-GUARDED-FAIL"))
