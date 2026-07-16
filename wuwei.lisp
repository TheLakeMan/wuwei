;;; wuwei.lisp — a provably-gated agent runner for Rusty.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; 無為 — "action without forcing." A wuwei agent will not act until the act
;;; is proven permitted. It is a ReAct loop with a hard proof gate in front of
;;; every side effect, built entirely on Rusty's existing checkers — no new
;;; interpreter code.
;;;
;;; TWO PROOF LAYERS
;;;
;;;   (1) STATIC, once, at boot — certify-registry:
;;;       every callable tool must
;;;         - have a spec (deftool-spec),
;;;         - be EFFECT-HONEST: check-effects finds nothing in its body beyond
;;;           what it declares, and
;;;         - have its declared effects fall inside the agent's effect BUDGET.
;;;       Fail any one and the agent REFUSES TO START — no LLM call, no side
;;;       effect, nothing.
;;;
;;;   (2) DYNAMIC, per call — gated-dispatch -> safe-call:
;;;       every action the model chooses is routed through safe-call, which
;;;       enforces arity + arg types + precondition BEFORE the tool body runs.
;;;       A violation is caught and returned to the model as feedback; the tool
;;;       never fires on bad input.
;;;
;;; Contrast Rusty's built-in (react-loop ...): it looks up whatever tool the
;;; model names and runs it immediately, ungated. wuwei is the gated version.
;;;
;;; Depends on: Rusty's std.lisp (safe-call, certify-tool-chain, deftool-spec,
;;; check-effects) and agent-tools.lisp, both auto-loaded. Requires the `rusty`
;;; interpreter — see README.

;; ── string helpers (std.lisp gives only substring / string-length) ──────────
(define (ws? c) (or (equal? c " ") (equal? c "\t") (equal? c "\r") (equal? c "\n")))
(define (lstrip s)
  (if (and (> (string-length s) 0) (ws? (substring s 0 1)))
      (lstrip (substring s 1 (string-length s))) s))
(define (rstrip s)
  (let ((n (string-length s)))
    (if (and (> n 0) (ws? (substring s (- n 1) n)))
        (rstrip (substring s 0 (- n 1))) s)))
(define (str-trim s) (rstrip (lstrip s)))

;; std.lisp's string-first-index matches a single CHAR only; we need a
;; substring index for multi-char markers like "FINAL:". -1 if absent.
(define (substr-index str sub)
  (let* ((slen (string-length str)) (sublen (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i sublen) slen) -1)
            ((string=? (substring str i (+ i sublen)) sub) i)
            (else (loop (+ i 1)))))))

(define (line-after-tag lines tag)
  (cond ((null? lines) #f)
        ((string-starts-with? (lstrip (car lines)) tag)
         (str-trim (substring (lstrip (car lines)) (string-length tag)
                              (string-length (lstrip (car lines))))))
        (else (line-after-tag (cdr lines) tag))))

(define (after-marker s marker)
  (let ((i (substr-index s marker)))
    (if (< i 0) #f
        (str-trim (substring s (+ i (string-length marker)) (string-length s))))))

;; ── the certification gate ──────────────────────────────────────────────────
;; A registry is a list of tool VALUES, each already given a spec via
;; deftool-spec. budget is a list of allowed effect-op symbols.
(define (over-budget tool budget)
  (let ((s (tool-spec (tool-name tool))))
    (if (not s) 'no-spec
        (filter (lambda (e) (not (member e budget))) (spec-effects s)))))

;; Returns 'certified, or (refused <why> <detail>). Nothing runs on refusal.
(define (certify-registry tools budget)
  (let ((chain (certify-tool-chain tools)))       ; spec + effect-honesty + deps
    (if (not (equal? chain 'certified))
        (list 'refused 'chain-not-certified chain)
        (let ((over (filter (lambda (t)
                              (let ((o (over-budget t budget)))
                                (and (list? o) (not (null? o)))))
                            tools)))
          (if (null? over) 'certified
              (list 'refused 'effect-budget-exceeded
                    (map (lambda (t) (list (tool-name t) (over-budget t budget))) over)))))))

;; ── gated per-call dispatch ─────────────────────────────────────────────────
(define (find-tool registry name)                 ; name is a string
  (cond ((null? registry) #f)
        ((equal? (tool-name (car registry)) (string->symbol name)) (car registry))
        (else (find-tool (cdr registry) name))))

(define (coerce-arg raw ty)
  (cond ((equal? ty 'number) (string->number raw))
        (else raw)))                              ; strings pass through

;; Multi-arg tools: the model separates arguments with " | ".
(define (split-args raw) (map str-trim (string-split raw "|")))

;; Coerce each raw arg by its positional type. Crucially does NOT truncate to
;; the spec's arity: extra args are kept (typed as strings) so safe-call's
;; arity check can REJECT the call rather than silently dropping arguments.
(define (coerce-args raws types)
  (if (null? raws) '()
      (cons (coerce-arg (car raws) (if (null? types) 'string (car types)))
            (coerce-args (cdr raws) (if (null? types) '() (cdr types))))))

;; Returns (ok <result>) or (rejected <reason>). The tool body runs ONLY if
;; safe-call's contract (arity + types + precondition) passes; any raise is
;; caught and turned into a rejection.
;; ── certificates: run what you certified ────────────────────────────────────
;; certify-registry answers "may this registry boot?" — but the answer goes
;; stale the moment anyone calls deftool-spec again. *tool-specs* is global and
;; keyed by tool NAME, and deftool-spec REPLACES that name's entry, so a
;; registry certified at boot can silently end up enforcing a spec it never
;; certified. That is not hypothetical: two tenants sharing a tool name is
;; enough (multi-tenant-test.lisp shows tenant A reading tenant B's box).
;;
;; Detecting the change is not possible: a precondition is a code value, and
;; code values are never `equal?` to anything (SPEC §equality) — the pinned spec
;; cannot even be compared to the live one. So don't detect. HOLD the spec you
;; certified and enforce that one, via Rusty 0.48.0's safe-call-with-spec. A
;; later registration then cannot reach a booted tenant at all.
;;
;; (certify-boot tools budget) -> (certificate ((tool spec) ...)) | (refused ...)
(define (certify-boot tools budget)
  (let ((c (certify-registry tools budget)))
    (if (not (equal? c 'certified))
        c
        (list 'certificate
              (map (lambda (t) (list t (tool-spec (tool-name t)))) tools)))))

(define (certificate? r)
  (and (list? r) (not (null? r)) (equal? (car r) 'certificate)))
(define (cert-entries c) (nth c 1))
(define (cert-find c name)
  (let ((hit (filter (lambda (e) (equal? (tool-name (nth e 0)) (string->symbol name)))
                     (cert-entries c))))
    (if (null? hit) #f (nth hit 0))))

;; A bare registry looks its spec up live — the pre-certificate behaviour, kept
;; so existing callers are unchanged (identical checks, identical messages).
(define (live-entry registry name)
  (let ((tool (find-tool registry name)))
    (and tool (list tool (tool-spec (tool-name tool))))))

(define (dispatch-entry entry name raw-arg)
  (if (not entry)
      (list 'rejected (format "no such tool in certified registry: ~a" name))
      (let* ((tool  (nth entry 0))
             (s     (nth entry 1))
             (types (map cadr (spec-param-types s)))
             (args  (coerce-args (split-args raw-arg) types)))
        (try-catch (list 'ok (apply safe-call-with-spec (cons s (cons tool args))))
                   (e) (list 'rejected e)))))

;; Takes a CERTIFICATE (specs pinned at boot — preferred) or a bare registry
;; (specs read live). Needs Rusty >= 0.48.0 for safe-call-with-spec.
(define (gated-dispatch registry name raw-arg)
  (dispatch-entry
    (if (certificate? registry)
        (cert-find registry name)
        (live-entry registry name))
    name raw-arg))

;; ── proof-writing macros: reusable, registered safety predicates ─────────────
;; A precondition runs as (apply pre <all the tool's args>), so it must accept
;; the tool's full arity. Writing one guard per arity — a 1-arg in-box?, then a
;; 2-arg wrapper of it — is pure friction. on-path adapts a single-resource
;; predicate to ANY arity: it checks the first argument (the path / url /
;; resource being gated) and ignores the rest. defguard names such a guard AND
;; records it in *guards*, so a registry's safety predicates become inspectable
;; data you can list (guards) and reuse (guard-of) across tools of any arity.
(define (on-path pred) (lambda (a . rest) (pred a)))
(define *guards* '())
(define (register-guard! name pred) (set! *guards* (cons (list name pred) *guards*)))
(define (guard-of name)
  (let loop ((g *guards*))
    (cond ((null? g) #f)
          ((equal? (car (car g)) name) (cadr (car g)))
          (else (loop (cdr g))))))
(define (guards) (map car *guards*))
(defmacro defguard (name param . body)
  ;; (defguard in-box p (and (string? p) (string-starts-with? p BOX) ...))
  ;; `param` binds the first tool argument; the same guard then gates a 1-arg
  ;; read-file and a 2-arg write-file, no per-arity wrapper.
  `(begin
     (define ,name (on-path (lambda (,param) ,@body)))
     (register-guard! ',name ,name)
     ',name))

;; ── refusal-recovery: stop an agent looping against the gate ─────────────────
;; If the model keeps proposing calls the gate rejects, it burns every step to
;; max-steps producing nothing. When the last `limit` audit rows are ALL gate
;; rejections, the agent is stuck; the loop halts early with 'stuck-refusing
;; rather than spin. (Inside the loop the audit is newest-first.)
(define *max-consecutive-refusals* 3)
(define (stuck-refusing? audit limit)
  (and (>= (length audit) limit)
       (all? (lambda (r) (equal? (nth r 3) 'rejected)) (take limit audit))))

;; ── streaming audit sink: feed rows to mingjian live, not only at exit ───────
;; audit-save writes the whole audit once, on termination. When *audit-sink* is
;; a 1-arg function, the loop hands it each (step tool input verdict) row the
;; instant it is produced — a live feed. streaming-audit-file returns such a
;; sink that keeps a growing model file VALID after every step, so mingjian's
;; mj-load works mid-run, not only at the end.
(define *audit-sink* #f)
(define (audit-sink! f) (set! *audit-sink* f))
(define (audit-sink-off!) (set! *audit-sink* #f))
(define (emit-audit-row! row) (when *audit-sink* (*audit-sink* row)) row)
(define (streaming-audit-file file)
  (let ((rows '()))
    (lambda (row)
      (set! rows (cons row rows))
      (save-model file (reverse rows)))))

;; ── the gated ReAct loop ────────────────────────────────────────────────────
(define (tool-menu registry)
  (string-join
    (map (lambda (t)
           (let ((s (tool-spec (tool-name t))))
             (format "- ~a(~a)  [effects: ~a]"
                     (tool-name t)
                     (string-join (map (lambda (pt) (symbol->string (car pt)))
                                       (spec-param-types s)) ", ")
                     (string-join (map symbol->string (spec-effects s)) ", "))))
         registry)
    "\n"))

;; A transport blip must never kill the runner: retry a few times, then return
;; (llm-error <msg>) so the loop can halt gracefully with its audit intact.
(define (llm-ask prompt tries)
  (try-catch (llm prompt 0.2 512)
             (e) (if (> tries 1) (llm-ask prompt (- tries 1)) (list 'llm-error e))))

;; Run a goal against a certified registry under an effect budget.
;; Returns (done <answer> <audit>) | (halted <why> ... <audit>) | (refused ...).
;; <audit> is a list of (step tool input verdict) rows — pure data.
(define (safe-agent goal registry budget max-steps)
  (let ((cert (certify-registry registry budget)))
    (if (not (equal? cert 'certified))
        (begin
          (println "  ⛔ REFUSED TO START — registry not certified:")
          (println "     " cert)
          (list 'refused cert))
        (let ((system (format
             (string-append
               "You are a gated agent. Use ONLY these tools:\n~a\n\n"
               "Respond with exactly:\nACTION: <tool>\nINPUT: <arg>   (multiple args separated by ' | ')\n"
               "or when finished:\nFINAL: <answer>\n"
               "Every call is contract-checked; a rejected call comes back as OBSERVATION.")
             (tool-menu registry))))
          (letrec
            ((step
              (lambda (n history audit)
                (if (>= n max-steps)
                    (list 'halted 'max-steps (reverse audit))
                    (let* ((prompt (format "~a\n\nGoal: ~a\n~a\nStep ~a:"
                                           system goal history (+ n 1)))
                           (resp (llm-ask prompt 3)))
                      (if (and (list? resp) (not (null? resp)) (equal? (car resp) 'llm-error))
                          (list 'halted 'llm-error (cadr resp) (reverse audit))
                          (cond
                            ((string-contains? resp "FINAL:")
                             (list 'done (after-marker resp "FINAL:") (reverse audit)))
                            ((string-contains? resp "ACTION:")
                             (let* ((lines (string-split resp "\n"))
                                    (act (line-after-tag lines "ACTION:"))
                                    (inp (line-after-tag lines "INPUT:"))
                                    (res (gated-dispatch registry act (if inp inp "")))
                                    (verdict (car res))
                                    (obs (cadr res))
                                    (audit2 (cons (list (+ n 1) act inp verdict) audit)))
                               (emit-audit-row! (car audit2))   ; live feed, if any
                               (println (format "  step ~a: ACTION=~a INPUT=~s  -> ~a"
                                                (+ n 1) act inp verdict))
                               (if (stuck-refusing? audit2 *max-consecutive-refusals*)
                                   (list 'halted 'stuck-refusing (reverse audit2))
                                   (step (+ n 1)
                                         (format "~a\nStep ~a: ACTION=~a INPUT=~a\nOBSERVATION[~a]: ~a"
                                                 history (+ n 1) act inp verdict obs)
                                         audit2))))
                            (else
                             (step (+ n 1)
                                   (format "~a\nThought: ~a" history (str-trim resp))
                                   audit)))))))))
            (step 0 "" '()))))))

;; ── audit export (pairs with mingjian) ──────────────────────────────────────
;; Pull the (step tool input verdict) rows out of any safe-agent result:
;;   (done <answer> <audit>)                → the audit
;;   (halted max-steps <audit>)             → the audit
;;   (halted stuck-refusing <audit>)        → the audit (looped against the gate)
;;   (halted llm-error <msg> <audit>)       → the audit
;;   (refused ...)                          → () — nothing ran, and that IS
;;                                            the honest audit of a refusal
(define (audit-of result)
  (cond ((not (list? result)) '())
        ((null? result) '())
        ((equal? (car result) 'done) (nth result 2))
        ((and (equal? (car result) 'halted) (equal? (cadr result) 'llm-error))
         (nth result 3))
        ((equal? (car result) 'halted) (nth result 2))
        (else '())))

;; Persist a run's audit as a versioned-JSON model file — the exact shape
;; mingjian (github.com/TheLakeMan/mingjian) consumes: mj-load it, feed it
;; to mj-breaches (the battle-test rule) or mj-audit->kg! (queries).
;; Returns the rows written.
(define (audit-save result file)
  (let ((rows (audit-of result)))
    (save-model file rows)
    rows))
