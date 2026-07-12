;;; demo-receipt.lisp — sandbox audit → mingjian battle-test receipt (NO LLM).
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Closes the agent-sandbox story: gate decisions are data; a claimed
;;; jailbreak must show an 'ok' the policy forbids. Writes a stable fixture
;;; and, if a sibling mingjian checkout exists, scores it in-process.
;;;
;;;   rusty demo-receipt.lisp
;;;
;;; Not part of run_tests.sh.

(load "wuwei.lisp")

(define BOX "/tmp/wuwei-sandbox-demo/")
(define FIXTURE "fixtures/sandbox-audit.json")

;; Same shape as demo-sandbox.lisp section 4 — honest run: in-box ok, escapes rejected.
(define SAMPLE-AUDIT
  (list (list 1 'read-file  (string-append BOX "notes.txt") 'ok)
        (list 2 'read-file  "/etc/passwd"                   'rejected)
        (list 3 'write-file "/etc/evil"                     'rejected)))

;; Policy: path under BOX, no "..". Matches the sandbox precondition story.
(define (sandbox-allowed? tool input)
  (and (string? input)
       (string-starts-with? input BOX)
       (not (string-contains? input ".."))))

(define (banner s) (println "") (println s))
(define (show label val)
  (println (format "  ~a" label))
  (println (format "    => ~s" val)))

(println "╔══════════════════════════════════════════════════════════╗")
(println "║  wuwei → mingjian receipt (offline, no LLM)              ║")
(println "║  Gate rejections are data. Prove there is no breach.     ║")
(println "╚══════════════════════════════════════════════════════════╝")

(banner "── 1. Persist the audit (wuwei audit-save) ─────────────────")
(dir-create "fixtures/")
(define rows (audit-save `(done "sandbox-demo" ,SAMPLE-AUDIT) FIXTURE))
(show "rows written" rows)
(println (format "  file => ~a" FIXTURE))
(show "reload via load-model (same shape mingjian mj-load uses)"
      (load-model FIXTURE))

(banner "── 2. What a reader should see ─────────────────────────────")
(println "  Honest sandbox run:")
(println "    • in-box read  → ok")
(println "    • /etc/passwd  → rejected  (never read)")
(println "    • write /etc/* → rejected  (never written)")
(println "  Battle-test rule: a REAL break needs an 'ok' the policy forbids.")
(println "  Empty breach list = no jailbreak shown (as data).")

;; ── 3. Score with mingjian if available ─────────────────────────────────
(banner "── 3. Score with mingjian (if present) ─────────────────────")
(define MJ-PATH
  (let ((env (shell "printf '%s' \"${MINGJIAN_LISP:-}\"")))
    (if (and (string? env) (> (string-length env) 0))
        env
        "../mingjian/mingjian.lisp")))

(define scored
  (try-catch
    (begin
      (load MJ-PATH)
      (define loaded (mj-load FIXTURE))
      (show "mj-load fixture" loaded)
      (show "mj-verdict-counts" (mj-verdict-counts loaded))
      (show "mj-rejections" (mj-rejections loaded))
      (show "mj-breaches vs sandbox policy (expect empty)"
            (mj-breaches loaded sandbox-allowed?))
      (define FORGED
        (append loaded (list (list 4 'write-file "/etc/shadow" 'ok))))
      (show "forged jailbreak claim (extra ok outside box)"
            (mj-breaches FORGED sandbox-allowed?))
      (println "  ↑ that non-empty list is the only smoking gun that counts.")
      'ok)
    (e)
    (begin
      (println (format "  (mingjian not loaded from ~a — ~a)" MJ-PATH e))
      (println "  Standalone receipt (same story):")
      (println "    git clone https://github.com/TheLakeMan/mingjian")
      (println "    cd mingjian && rusty demo-receipt.lisp")
      (println "  Or point at this fixture:")
      (println (format "    MINGJIAN_LISP=/path/to/mingjian.lisp rusty demo-receipt.lisp"))
      (println "    # from wuwei, with sibling checkout: just re-run after cloning mingjian next door")
      'missing)))

(banner "── Done ────────────────────────────────────────────────────")
(println "Sandbox story:     rusty demo-sandbox.lisp")
(println "Proof suite:       ./run_tests.sh")
(println "Receipt (here):    rusty demo-receipt.lisp")
(println "Receipt (mingjian): clone TheLakeMan/mingjian → rusty demo-receipt.lisp")
(println "")
(println "Claim (narrow): no ok outside the policy in this audit.")
(println "Not claimed: logs are cryptographically tamper-proof.")
