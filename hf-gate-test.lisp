;;; hf-gate-test.lisp — deterministic golden test for gated model fetching.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; NO LLM, NO NETWORK. The "registry" is a local directory; the fixture bytes
;;; are fixed, so every hash below is a real SHA-256 that never changes.

(load "wuwei.lisp")
(load "guards.lisp")
(load "hf-gate.lisp")

;; ── fixtures: a local hub standing in for the model registry ────────────────
(define HUB "/tmp/wuwei-hf-hub/")
(define BOX "/tmp/wuwei-hf-box/")
(define (scrub! p) (when (file-exists? p) (file-delete p)))
(dir-create (str HUB "acme/tiny"))
(scrub! (str HUB "acme/tiny/model.safetensors"))
(scrub! (str HUB "acme/tiny/model.bin"))
(scrub! (str HUB "acme/tiny/extra.safetensors"))
(scrub! (str BOX "models/model.safetensors"))
(scrub! (str BOX "models/sneaked"))

(file-write (str HUB "acme/tiny/model.safetensors") "SAFETENSORS-DEMO-BYTES-v1\n")
(file-write (str HUB "acme/tiny/model.bin")         "PICKLE-STYLE-BYTES\n")
(file-write (str HUB "acme/tiny/extra.safetensors") "UNPINNED-BYTES\n")

;; Record the pin the way a lockfile would: hash the artifact you audited.
(define GOOD-URL "https://hub.example/acme/tiny/model.safetensors")
(define GOOD-PIN (file-hash (str HUB "acme/tiny/model.safetensors")))

(hf-config! HUB BOX '("hub.example") (list (list GOOD-URL GOOD-PIN)))

(define FETCH-BUDGET HF-FETCH-EFFECTS)
(define HONEST-REG (list fetch-model))
(define LIAR-REG   (list fetch-model sneaky-fetch))

(define (row tag val) (println (format "~a => ~s" tag val)))

(println "── LAYER 1: boot — the registry must prove itself ───────────")
(row "01 honest fetcher / fetch budget         " (certify-registry HONEST-REG FETCH-BUDGET))
(row "02 fetcher that hides its write (LIES)   " (certify-registry LIAR-REG FETCH-BUDGET))
(row "03 honest fetcher / read-only budget     " (certify-registry HONEST-REG '(file-read)))

(println "")
(println "── LAYER 2: per-call — prove the fetch before any byte moves ─")
(row "04 pinned safetensors on allowed host    " (gated-dispatch HONEST-REG "fetch-model" GOOD-URL))
(row "05 models/ after install                 " (dir-list (str BOX "models")))
(row "06 pickle-style .bin (format gate)       " (gated-dispatch HONEST-REG "fetch-model" "https://hub.example/acme/tiny/model.bin"))
(row "07 off-allowlist host                    " (gated-dispatch HONEST-REG "fetch-model" "https://evil.example/acme/tiny/model.safetensors"))
(row "08 userinfo escape (parsed, not prefix)  " (gated-dispatch HONEST-REG "fetch-model" "https://hub.example@evil.example/acme/tiny/model.safetensors"))
(row "09 allowed + safetensors but UNPINNED    " (gated-dispatch HONEST-REG "fetch-model" "https://hub.example/acme/tiny/extra.safetensors"))

(println "")
(println "── GATE 4: supply-chain tamper after pinning ────────────────")
(println "   (the hub artifact is replaced AFTER the pin was recorded)")
(file-write (str HUB "acme/tiny/model.safetensors") "TAMPERED-BYTES\n")
(scrub! (str BOX "models/model.safetensors"))
(row "10 fetch of the tampered artifact        " (gated-dispatch HONEST-REG "fetch-model" GOOD-URL))
(row "11 quarantine/ after the refusal         " (dir-list (str BOX "quarantine")))
(row "12 models/ after the refusal             " (dir-list (str BOX "models")))

(println "")
(println "── RECEIPT: a breach is an 'ok' the policy forbids ──────────")
(define HONEST-AUDIT
  (list (list 1 "fetch-model" GOOD-URL 'ok)
        (list 2 "fetch-model" "https://hub.example/acme/tiny/model.bin" 'rejected)
        (list 3 "fetch-model" "https://evil.example/m.safetensors" 'rejected)))
(define FORGED-AUDIT
  (append HONEST-AUDIT
          (list (list 4 "fetch-model" "https://hub.example/acme/tiny/model.bin" 'ok))))
(row "13 hf-breaches on the honest audit       " (hf-breaches HONEST-AUDIT))
(row "14 hf-breaches on the forged audit       " (hf-breaches FORGED-AUDIT))

(println "")
(println "Claim (narrow): pinned, allowlisted, format-gated fetches by an")
(println "effect-honest tool; no artifact reaches models/ without matching")
(println "its pin. Not claimed: artifact benignity, platform security.")
