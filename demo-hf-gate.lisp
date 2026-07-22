;;; demo-hf-gate.lisp — gated model fetching, 60-second offline story (NO LLM).
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; The July 2026 Hugging Face incident pattern: an agent whose only security
;;; layer was its model's refusals — with the refusals dialed down. Here the
;;; fetch of a model artifact is a wuwei tool: the agent may PROPOSE any
;;; download; a byte moves only after the call is proven permitted.
;;;
;;;   rusty demo-hf-gate.lisp
;;;
;;; Same fixtures as hf-gate-test.lisp (the golden proof); this file is the
;;; human transcript. Offline: a local directory stands in for the registry.

(load "wuwei.lisp")
(load "guards.lisp")
(load "hf-gate.lisp")

(define HUB "/tmp/wuwei-hf-hub/")
(define BOX "/tmp/wuwei-hf-box/")
(define (scrub! p) (when (file-exists? p) (file-delete p)))
(dir-create (str HUB "acme/tiny"))
(scrub! (str BOX "models/model.safetensors"))
(file-write (str HUB "acme/tiny/model.safetensors") "SAFETENSORS-DEMO-BYTES-v1\n")
(file-write (str HUB "acme/tiny/model.bin")         "PICKLE-STYLE-BYTES\n")

(define GOOD-URL "https://hub.example/acme/tiny/model.safetensors")
(define GOOD-PIN (file-hash (str HUB "acme/tiny/model.safetensors")))
(hf-config! HUB BOX '("hub.example") (list (list GOOD-URL GOOD-PIN)))

(define (banner s) (println "") (println s))
(define (show label val)
  (println (format "  ~a" label))
  (println (format "    => ~s" val)))

(println "╔══════════════════════════════════════════════════════════╗")
(println "║  wuwei — gated model fetch demo (offline, no LLM)        ║")
(println "║  The agent may propose any download.                     ║")
(println "║  A byte moves only after the call is proven permitted.   ║")
(println "╚══════════════════════════════════════════════════════════╝")
(println (format "Registry stand-in: ~a   Install box: ~a" HUB BOX))
(println (format "Pin lockfile: model.safetensors -> ~a" GOOD-PIN))

(banner "── 1. Boot: the fetcher must prove what it touches ─────────")
(show "honest fetcher under the fetch budget"
      (certify-registry (list fetch-model) HF-FETCH-EFFECTS))
(show "a fetcher that hides its write  (must refuse)"
      (certify-registry (list fetch-model sneaky-fetch) HF-FETCH-EFFECTS))

(banner "── 2. Per-call gates: proven BEFORE any byte moves ─────────")
(show "pinned .safetensors on the allowed host"
      (gated-dispatch (list fetch-model) "fetch-model" GOOD-URL))
(show "pickle-style .bin  (format gate — never fetched)"
      (gated-dispatch (list fetch-model) "fetch-model" "https://hub.example/acme/tiny/model.bin"))
(show "userinfo escape hub.example@evil.example  (parsed host, not prefix)"
      (gated-dispatch (list fetch-model) "fetch-model" "https://hub.example@evil.example/acme/tiny/model.safetensors"))

(banner "── 3. Supply-chain tamper: artifact replaced after pinning ──")
(file-write (str HUB "acme/tiny/model.safetensors") "TAMPERED-BYTES\n")
(scrub! (str BOX "models/model.safetensors"))
(show "fetch of the tampered artifact  (must refuse)"
      (gated-dispatch (list fetch-model) "fetch-model" GOOD-URL))
(show "models/ afterwards — the tampered bytes never landed"
      (dir-list (str BOX "models")))

(banner "── 4. Receipt: a breach is an 'ok' the policy forbids ──────")
(define FORGED (list (list 1 "fetch-model" GOOD-URL 'ok)
                     (list 2 "fetch-model" "https://hub.example/acme/tiny/model.bin" 'ok)))
(show "hf-breaches on a forged audit (the .bin 'ok' is the gun)"
      (hf-breaches FORGED))

(banner "── Done ────────────────────────────────────────────────────")
(println "Golden proof (bit-identical):  ./run_tests.sh  (hf-gate-test.lisp)")
(println "")
(println "Claim (narrow): pinned, allowlisted, format-gated fetches by an")
(println "effect-honest tool; nothing reaches models/ without matching its pin.")
(println "Not claimed: artifact benignity, platform security, a scanner.")
