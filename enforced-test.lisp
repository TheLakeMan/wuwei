;;; enforced-test.lisp — the filesystem boundary is the ENFORCED sandbox, not the
;;; Lisp guard. (Golden — deterministic, no LLM.)
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; wuwei-confine! (wuwei.lisp) fences the whole process under BOX with Rusty's
;;; sandbox (>=0.82.0): the always-on userspace floor + best-effort Landlock. The
;;; per-call safe-under? guard and the boot-time check-effects stay as DEFENSE IN
;;; DEPTH; the ground-truth FS boundary becomes the fence. The point of this test:
;;; even a tool with a DELIBERATELY WEAK precondition (always #t — a stand-in for
;;; a guard bug) cannot write outside the box, because the sandbox refuses the
;;; open() no matter what the Lisp guard decided.
;;;
;;; Assertions are kernel-INDEPENDENT — the userspace floor refuses out-of-box ops
;;; on EVERY platform, so only the kernel STATUS symbol varies (asserted as a
;;; symbol, never a value: fully-enforced on a Landlock kernel, not-enforced
;;; without one). The kernel-only hardening delta (a live TOCTOU the floor can't
;;; win) is shown in the non-golden probe-enforced.sh, not here.

(load "wuwei.lisp")
(load "demo-tools.lisp")
(load "guards.lisp")

(define BOX "/tmp/wuwei-enforced-box/")
(dir-create BOX)
(file-write (string-append BOX "ok.txt") "in-box")

(define GUARD (under-guard BOX))
(deftool-spec read-file  '((path string))                  '(file-read)  GUARD '())
(deftool-spec write-file '((path string) (content string)) '(file-write) GUARD '())

;; A tool whose precondition ALWAYS passes — a stand-in for a buggy guard. Its
;; effect is honestly declared (file-write), so certify-registry accepts it; only
;; the enforced sandbox stops its escape.
(deftool weak-write (path content)
  "weak guard on purpose"
  (file-write path content))
(deftool-spec weak-write '((path string) (content string)) '(file-write) (lambda (p . rest) #t) '())

(define REG (list read-file write-file weak-write))

;; Confine the process under BOX. Kernel status is platform-dependent → assert it
;; is a symbol only (fully-enforced here, not-enforced on a kernel w/o Landlock).
(println (list 'confined-status-symbol (symbol? (wuwei-confine! BOX))))

;; In-box read still works under confinement.
(println (list 'in-box-read (gated-dispatch REG "read-file" (string-append BOX "ok.txt"))))

;; Out-of-box read: rejected (the guard's own realpath/symlink probe hits the
;; sandbox floor and is refused — either way, rejected).
(println (list 'out-read-rejected
  (equal? (car (gated-dispatch REG "read-file" "/etc/passwd")) 'rejected)))

;; THE POINT: weak-write's precondition passes (guard bug simulated), but writing
;; OUTSIDE the box is refused by the sandbox — the boundary is the fence, not the
;; guard — while an in-box write through the same weak tool still works.
(println (list 'weak-out-rejected
  (equal? (car (gated-dispatch REG "weak-write" "/tmp/wuwei-escape.txt | x")) 'rejected)))
(println (list 'weak-in-ok
  (equal? (car (gated-dispatch REG "weak-write" (string-append BOX "w.txt | x"))) 'ok)))
