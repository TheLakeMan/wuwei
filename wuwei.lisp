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
(define (gated-dispatch registry name raw-arg)
  (let ((tool (find-tool registry name)))
    (if (not tool)
        (list 'rejected (format "no such tool in certified registry: ~a" name))
        (let* ((s     (tool-spec (tool-name tool)))
               (types (map cadr (spec-param-types s)))
               (args  (coerce-args (split-args raw-arg) types)))
          (try-catch (list 'ok (apply safe-call (cons tool args)))
                     (e) (list 'rejected e))))))

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
                                    (obs (cadr res)))
                               (println (format "  step ~a: ACTION=~a INPUT=~s  -> ~a"
                                                (+ n 1) act inp verdict))
                               (step (+ n 1)
                                     (format "~a\nStep ~a: ACTION=~a INPUT=~a\nOBSERVATION[~a]: ~a"
                                             history (+ n 1) act inp verdict obs)
                                     (cons (list (+ n 1) act inp verdict) audit))))
                            (else
                             (step (+ n 1)
                                   (format "~a\nThought: ~a" history (str-trim resp))
                                   audit))))))))
            (step 0 "" '()))))))
