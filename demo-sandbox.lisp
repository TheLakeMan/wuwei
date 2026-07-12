;;; demo-sandbox.lisp — 60-second offline sandbox story (NO LLM).
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Human-readable transcript of the agent-sandbox guarantee. Same fixtures
;;; as gate-test.lisp, but written for a first-time reader — not the golden
;;; suite. Not part of run_tests.sh.
;;;
;;;   rusty demo-sandbox.lisp

(load "wuwei.lisp")
(load "demo-tools.lisp")

(define BOX "/tmp/wuwei-sandbox-demo/")
(dir-create BOX)
(file-write (string-append BOX "notes.txt") "buy milk\nship v2\n")

(define (in-box? p)
  (and (string? p) (string-starts-with? p BOX) (not (string-contains? p ".."))))

(define READ-ONLY  '(file-read dir-list file-exists?))
(define READ-WRITE '(file-read dir-list file-exists? file-write))

(deftool-spec read-file    '((path string))                  '(file-read)     in-box? '())
(deftool-spec list-dir     '((path string))                  '(dir-list)      in-box? '())
(deftool-spec file-exists  '((path string))                  '(file-exists?)  in-box? '())
(define (wpre p c) (in-box? p))
(deftool-spec write-file   '((path string) (content string)) '(file-write)    wpre '())
(deftool-spec sneaky-write '((path string) (content string)) '()              wpre '())

(define READ-REG  (list read-file list-dir file-exists))
(define WRITE-REG (list read-file write-file))
(define LIAR-REG  (list read-file sneaky-write))

(define (banner s)
  (println "")
  (println s))

(define (show label val)
  (println (format "  ~a" label))
  (println (format "    => ~s" val)))

(println "╔══════════════════════════════════════════════════════════╗")
(println "║  wuwei — agent sandbox demo (offline, no LLM)            ║")
(println "║  Model may propose anything. Side effects need a proof.  ║")
(println "╚══════════════════════════════════════════════════════════╝")
(println (format "Sandbox root: ~a" BOX))
(println "Effect budget (this agent): file-read, dir-list, file-exists?")

;; ── Layer 1 ──────────────────────────────────────────────────────────────────
(banner "── 1. Boot gate: certify the tool registry ─────────────────")
(println "Before any step, every tool must have a honest spec and fit the budget.")
(show "read-only tools + read-only budget"
      (certify-registry READ-REG READ-ONLY))
(show "write-file in the registry + read-only budget  (must refuse)"
      (certify-registry WRITE-REG READ-ONLY))
(show "tool that writes but declares no effects  (must refuse)"
      (certify-registry LIAR-REG READ-WRITE))

;; ── Layer 2 ──────────────────────────────────────────────────────────────────
(banner "── 2. Per-call gate: every tool call is checked ────────────")
(println "In-box read is allowed. Path escape never reaches the filesystem.")
(show "read notes.txt inside the sandbox"
      (gated-dispatch READ-REG "read-file" (string-append BOX "notes.txt")))
(show "read /etc/passwd  (must reject — precondition)"
      (gated-dispatch READ-REG "read-file" "/etc/passwd"))
(show "write-file when it is not even in the registry  (must reject)"
      (gated-dispatch READ-REG "write-file" (string-append BOX "x")))
(show "write outside the sandbox  (must reject)"
      (gated-dispatch WRITE-REG "write-file" (string-append "/etc/evil | hello")))

;; ── Full agent boot ──────────────────────────────────────────────────────────
(banner "── 3. safe-agent: over-budget registry never starts ────────")
(println "No LLM call. No tool body. Empty audit = nothing ran.")
(define boot (safe-agent "anything" WRITE-REG READ-ONLY 3))
(show "safe-agent with write tools under a read-only budget" boot)
(show "audit-of that result (honestly empty)" (audit-of boot))

;; ── Audit as data ────────────────────────────────────────────────────────────
(banner "── 4. Audit is data (mingjian-ready receipt) ───────────────")
(define sample-audit
  '((1 read-file "/tmp/wuwei-sandbox-demo/notes.txt" ok)
    (2 read-file "/etc/passwd" rejected)
    (3 write-file "/etc/evil" rejected)))
(show "example run audit rows" sample-audit)
(define AF (string-append BOX "audit.json"))
(audit-save `(done "demo" ,sample-audit) AF)
(println (format "  saved => ~a" AF))
(println "  Next — the receipt (battle-test rule, as data):")
(println "    rusty demo-receipt.lisp")
(println "  That writes fixtures/sandbox-audit.json and scores mj-breaches")
(println "  (empty = no jailbreak shown). A real break needs an 'ok' outside policy.")

(banner "── Done ────────────────────────────────────────────────────")
(println "Receipt (audit → mingjian):         rusty demo-receipt.lisp")
(println "Proof suite (bit-identical golden):  ./run_tests.sh")
(println "Live model (optional, needs LLM):      rusty demo-shot.lisp")
(println "  RUSTY_LLM_URL default: http://localhost:8080/v1/chat/completions")
(println "")
(println "Claim (narrow): effect-honest registry + per-call preconditions.")
(println "Not claimed: unjailbreakable AI / OS isolation replacement.")
