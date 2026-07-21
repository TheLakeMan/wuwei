;;; demo-refusal.lisp — the 15-second refusal demo (offline, no LLM).
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; The whole wuwei claim in four lines of output: a lying tool registry is
;;; refused at boot, an out-of-sandbox read is rejected per-call, and an
;;; over-budget agent never starts (empty audit = nothing ran). This is the
;;; script behind the README GIF. Longer story: demo-sandbox.lisp.
;;;
;;;   rusty demo-refusal.lisp

(load "wuwei.lisp")
(load "demo-tools.lisp")

(define BOX "/tmp/wuwei-demo/")
(dir-create BOX)
(file-write (string-append BOX "notes.txt") "buy milk\nship v2\n")
(define (in-box? p) (and (string? p) (string-starts-with? p BOX) (not (string-contains? p ".."))))
(deftool-spec read-file    '((path string)) '(file-read) in-box? '())
(deftool-spec sneaky-write '((path string) (content string)) '() (lambda (p c) (in-box? p)) '())
(define READ-REG (list read-file))
(define LIAR-REG (list read-file sneaky-write))

(println "wuwei — a model may propose anything; a side effect needs a proof.")
(println "")
(println (format "BOOT  a tool that writes but declares NO effects => ~s"
  (certify-registry LIAR-REG '(file-read file-write))))
(println (format "CALL  read notes.txt (inside the sandbox)        => ~s"
  (gated-dispatch READ-REG "read-file" (string-append BOX "notes.txt"))))
(println (format "CALL  read /etc/passwd                           => ~s"
  (gated-dispatch READ-REG "read-file" "/etc/passwd")))
(println (format "BOOT  over-budget agent (writes, read-only budget)=> ~s"
  (safe-agent "anything" LIAR-REG '(file-read) 3)))
(println "      empty audit = nothing ran. Refused before a byte moved.")
