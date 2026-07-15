;;; guards.lisp — canonicalizing path guards for wuwei preconditions.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; A precondition that checks a path *string* ("starts with /box/") is defeated
;;; by a symlink inside the box pointing out: every filesystem builtin FOLLOWS
;;; symlinks, so the effect lands outside the fence. safe-under? resolves the
;;; REAL location first, using Rusty's no-follow primitives (≥0.42.0):
;;;   file-symlink?  — lstat: is the path itself a symlink (incl. dangling)?
;;;   file-realpath  — canonicalize: real absolute path, or Nil if unresolvable.
;;;
;;; It rejects any symlink LEAF outright (a confinement guard never writes/reads
;;; through one), and requires the canonical path — or, for a not-yet-created
;;; file, its canonical parent — to sit under the canonical box. Canonicalizing
;;; the parent is what catches a symlink in a MIDDLE path component.
;;;
;;; HONEST SCOPE: this closes every *planted* symlink. It does NOT close a live
;;; TOCTOU race (a component swapped between check and open) — that is a kernel
;;; job. For a hostile filesystem, run wuwei inside real OS isolation too.

;; everything up to the last "/"; "." when there is no slash, "/" at root.
(define (path-parent p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) ".")
          ((equal? (substring p i (+ i 1)) "/")
           (if (= i 0) "/" (substring p 0 i)))
          (else (loop (- i 1))))))

;; everything after the last "/".
(define (path-basename p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) p)
          ((equal? (substring p i (+ i 1)) "/")
           (substring p (+ i 1) (string-length p)))
          (else (loop (- i 1))))))

;; rp equal to, or strictly inside, base — both canonical absolute paths.
(define (path-under? base rp)
  (or (equal? rp base) (string-starts-with? rp (str base "/"))))

;; The guard. box = a directory path (trailing slash optional).
(define (safe-under? box path)
  (let ((bc (file-realpath box)))              ; canonical box (must exist)
    (and (string? path)
         bc
         (not (file-symlink? path))            ; never trust a symlink leaf
         (let ((rp (if (file-exists? path)
                       (file-realpath path)     ; existing: resolve the whole path
                       (let ((pc (file-realpath (path-parent path))))
                         (and pc (str pc "/" (path-basename path)))))))
           (and (string? rp) (path-under? bc rp))))))

;; Adapt safe-under? into a precondition of ANY tool arity, gating on the first
;; argument (the path). Pairs with deftool-spec exactly like in-box? did:
;;   (deftool-spec read-file '((path string)) '(file-read) (under-guard BOX) '())
(define (under-guard box)
  (lambda (p . rest) (safe-under? box p)))
