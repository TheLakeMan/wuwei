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
(println "gate-test: done")
