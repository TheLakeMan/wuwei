;;; multi-tenant-test.lisp — one gate, many tenants, and the footgun in between.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Shows the effect-honest boundary composing per tenant: each tenant gets its
;;; own registry, its own effect budget, and its own box — so a tenant certified
;;; read-only cannot boot with a write tool, and a tenant cannot reach another's
;;; files.
;;;
;;; It leads with the FOOTGUN, because it is real and it is silent: *tool-specs*
;;; is global and keyed by TOOL NAME, and deftool-spec REPLACES the entry for
;;; that name. Give two tenants their own precondition for the same tool name and
;;; the second one wins — for BOTH of them. Tenant A then reads tenant B's box.
;;; The fix is not subtle either: per-tenant tools get per-tenant NAMES.
;;;
;;; Deterministic, no LLM. Fixture under /tmp only.

(load "wuwei.lisp")
(load "guards.lisp")

(define (row tag v) (println (format "~a => ~s" tag v)))

;; ── fixture: two tenants, two boxes, one secret each ────────────────────────
(define ROOT "/tmp/wuwei-tenants")
(define BOX-A (str ROOT "/tenant-a"))
(define BOX-B (str ROOT "/tenant-b"))
(shell (str "rm -rf " ROOT))
(dir-create BOX-A)
(dir-create BOX-B)
(file-write (str BOX-A "/mine.txt") "A-DATA")
(file-write (str BOX-B "/mine.txt") "B-SECRET")

(println "── the footgun: specs are global, keyed by TOOL NAME ──")
;; The obvious way to do this is wrong. One tool name, a spec per tenant:
;; the second deftool-spec silently replaces the first, for everyone.
(deftool shared-read (path) "Read a file" (file-read path))
(deftool-spec shared-read '((path string)) '(file-read) (under-guard BOX-A) '())
(define NAIVE-A (list shared-read))
(deftool-spec shared-read '((path string)) '(file-read) (under-guard BOX-B) '())
(define NAIVE-B (list shared-read))
;; Tenant A's own registry now enforces tenant B's fence. Both rows are wrong:
(row "A reads B's secret (LEAK)         " (gated-dispatch NAIVE-A "shared-read" (str BOX-B "/mine.txt")))
(row "A rejected from its OWN box       " (gated-dispatch NAIVE-A "shared-read" (str BOX-A "/mine.txt")))

(println "")
(println "── the fix: a tenant's tools carry the tenant's name ──")
;; Distinct tool values, distinct names -> distinct spec entries. Nothing to
;; collide, so nothing to silently overwrite.
(deftool a-read (path) "Read a file for tenant A" (file-read path))
(deftool b-read (path) "Read a file for tenant B" (file-read path))
(deftool b-write (path content) "Write a file for tenant B" (file-write path content))
(deftool-spec a-read  '((path string)) '(file-read)  (under-guard BOX-A) '())
(deftool-spec b-read  '((path string)) '(file-read)  (under-guard BOX-B) '())
(deftool-spec b-write '((path string) (content string)) '(file-write) (under-guard BOX-B) '())

(define REG-A (list a-read))
(define REG-B (list b-read b-write))
(define READ-ONLY  '(file-read))
(define READ-WRITE '(file-read file-write))

(row "A reads its own box (ok)          " (gated-dispatch REG-A "a-read" (str BOX-A "/mine.txt")))
(row "A cannot reach B's box            " (gated-dispatch REG-A "a-read" (str BOX-B "/mine.txt")))
(row "B reads its own box (ok)          " (gated-dispatch REG-B "b-read" (str BOX-B "/mine.txt")))
(row "B cannot reach A's box            " (gated-dispatch REG-B "b-read" (str BOX-A "/mine.txt")))
;; A's registry has no write tool at all — there is nothing to gate.
(row "A has no write tool to call       " (gated-dispatch REG-A "b-write" (str BOX-A "/x.txt")))

(println "")
(println "── budgets are per tenant, and they are a BOOT check ──")
;; This is the part that isn't a per-call rejection: a registry that exceeds its
;; tenant's budget never certifies, so the tenant never starts. Nothing runs.
(row "A read-only: certifies            " (certify-registry REG-A READ-ONLY))
(row "B read-write: certifies           " (certify-registry REG-B READ-WRITE))
(row "B's registry under A's budget     " (certify-registry REG-B READ-ONLY))
;; The same tool value, judged against two budgets: the tool didn't change, the
;; tenant's permission did. That is the boundary composing.
(row "A's registry under B's budget     " (certify-registry REG-A READ-WRITE))

(shell (str "rm -rf " ROOT))
(println "")
(println "multi-tenant-test: done")
