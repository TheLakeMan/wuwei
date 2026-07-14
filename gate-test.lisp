;;; gate-test.lisp — deterministic golden test for the wuwei proof gate.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; NO LLM. Every check here is reproducible: it exercises the certification
;;; gate and per-call dispatch directly. This is the file that proves the
;;; guarantee — "nothing runs until it is proven" — on every run.

(load "wuwei.lisp")
(load "demo-tools.lisp")

;; ── sandbox fixture ─────────────────────────────────────────────────────────
(define BOX "/tmp/wuwei-gatebox/")
(dir-create BOX)
(file-write (string-append BOX "notes.txt") "buy milk\nship v2\n")

;; a call is in-sandbox iff it stays under BOX and never escapes with ".."
(define (in-box? p) (and (string? p) (string-starts-with? p BOX) (not (string-contains? p ".."))))

;; ── effect budgets ──────────────────────────────────────────────────────────
(define READ-ONLY  '(file-read dir-list file-exists?))
(define READ-WRITE '(file-read dir-list file-exists? file-write))

;; ── specs ───────────────────────────────────────────────────────────────────
(deftool-spec read-file    '((path string))                 '(file-read)     in-box? '())
(deftool-spec list-dir     '((path string))                 '(dir-list)      in-box? '())
(deftool-spec file-exists  '((path string))                 '(file-exists?)  in-box? '())
;; 2-arg tools: safe-call applies the precondition to ALL args, so it must be
;; 2-arity. It still gates on the path (first arg).
(define (wpre p c) (in-box? p))
(deftool-spec write-file   '((path string) (content string)) '(file-write)    wpre '())
(deftool-spec sneaky-write '((path string) (content string)) '()             wpre '())  ; LIES

(define READ-REG  (list read-file list-dir file-exists))
(define WRITE-REG (list read-file write-file))
(define LIAR-REG  (list read-file sneaky-write))

(define (row tag val) (println (format "~a => ~s" tag val)))

(println "── LAYER 1: static certification (at boot) ──────────────────")
(row "01 read-only reg / read-only budget      " (certify-registry READ-REG READ-ONLY))
(row "02 write reg / read-only budget          " (certify-registry WRITE-REG READ-ONLY))
(row "03 write reg / read-write budget         " (certify-registry WRITE-REG READ-WRITE))
(row "04 effect-dishonest tool (declares none) " (certify-registry LIAR-REG READ-WRITE))

(println "")
(println "── LAYER 2: per-call gated dispatch ─────────────────────────")
(row "05 in-sandbox read                       " (gated-dispatch READ-REG "read-file" (string-append BOX "notes.txt")))
(row "06 path-escape to /etc/passwd            " (gated-dispatch READ-REG "read-file" "/etc/passwd"))
(row "07 tool not in registry                  " (gated-dispatch READ-REG "write-file" (string-append BOX "x")))
(row "08 wrong arity (2 args to 1-arg tool)    " (gated-dispatch READ-REG "read-file" (string-append BOX "a | " BOX "b")))
(row "09 multi-arg in-sandbox write            " (gated-dispatch WRITE-REG "write-file" (string-append BOX "out.txt | hello")))
(row "10 multi-arg out-of-sandbox write        " (gated-dispatch WRITE-REG "write-file" (string-append "/etc/evil | hello")))

(println "")
(println "── boot refusal returns before any step (no LLM) ────────────")
(row "11 safe-agent on over-budget registry    " (safe-agent "anything" WRITE-REG READ-ONLY 3))

(println "")
(println "── certified loop entry (regression: exercises the LLM path) ─")
;; A certified registry with max-steps 0 returns before any llm call but still
;; builds the system prompt + letrec loop — the exact code path a boot refusal
;; skips. Guards the loop-entry structure without needing a live model.
(row "12 certified agent, max-steps 0 (no LLM)  " (safe-agent "noop" READ-REG READ-ONLY 0))

(println "")
(println "── audit export: rows out of any result, mingjian-ready ─────")
(row "13 audit of a done result                "
     (audit-of '(done "answer" ((1 read-file "/tmp/wuwei-gatebox/notes.txt" ok)
                                (2 write-file "/etc/passwd" rejected)))))
(row "14 audit of a boot refusal (nothing ran) " (audit-of (safe-agent "anything" WRITE-REG READ-ONLY 3)))
(define AF (string-append BOX "audit.json"))
(row "15 saved rows reload identically         "
     (let ((rows (audit-save '(halted max-steps ((1 list-dir "/tmp/wuwei-gatebox/" ok))) AF)))
       (equal? rows (load-model AF))))
(file-delete AF)

(println "")
(println "── refusal-recovery: break a loop of gate rejections ────────")
;; The step loop halts when the last N audit rows are all rejections instead of
;; spinning to max-steps. The decision is this pure predicate (audit newest-first).
(row "16 3 rejections in a row (limit 3)        "
     (stuck-refusing? '((3 t "x" rejected) (2 t "y" rejected) (1 t "z" rejected)) 3))
(row "17 a success breaks the streak            "
     (stuck-refusing? '((3 t "x" rejected) (2 t "y" ok) (1 t "z" rejected)) 3))
(row "18 too few rows to be stuck yet           "
     (stuck-refusing? '((2 t "x" rejected) (1 t "y" rejected)) 3))

(println "")
(println "── proof-writing macro: one guard, any tool arity ──────────")
;; defguard registers a reusable safety predicate that gates on the resource
;; (first arg) and fits a tool of ANY arity — the wpre-per-arity friction gone.
(defguard boxed p (and (string? p) (string-starts-with? p BOX) (not (string-contains? p ".."))))
(row "19 guard is registered + inspectable      " (if (guard-of 'boxed) #t #f))
(row "20 gates a 1-arg call (in sandbox)        " ((guard-of 'boxed) (string-append BOX "n")))
(row "21 gates a 2-arg call (path escapes)      " ((guard-of 'boxed) "/etc/passwd" "payload"))
;; and it works as a real precondition, wired straight into a spec + safe-call:
(deftool-spec write-file '((path string) (content string)) '(file-write) boxed '())
(row "22 same guard as a 2-arg precondition     "
     (gated-dispatch (list write-file) "write-file" (string-append BOX "g.txt | hi")))

(println "")
(println "── streaming audit sink: file valid mid-run, not at exit ────")
;; Each row reaches the sink as it is produced; the model file mj-load reads is
;; valid after every step, not only on termination.
(define SF (string-append BOX "stream.json"))
(define sink (streaming-audit-file SF))
(sink '(1 list-dir "/tmp/wuwei-gatebox/" ok))
(row "23 after 1 streamed row, file has 1 row   " (length (load-model SF)))
(sink '(2 read-file "/tmp/wuwei-gatebox/notes.txt" ok))
(row "24 after 2 streamed rows, file has 2 rows " (length (load-model SF)))
(row "25 streamed rows preserve feed order      "
     (equal? (load-model SF)
             '((1 list-dir "/tmp/wuwei-gatebox/" ok)
               (2 read-file "/tmp/wuwei-gatebox/notes.txt" ok))))
(file-delete SF)

(println "")
(println "gate-test: done")
