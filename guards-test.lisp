;;; guards-test.lisp — the symlink escape, and safe-under? closing it.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Builds a real fixture — a sandbox box with symlinks planted inside pointing
;;; OUT — and shows a string-prefix guard would wave them through while the
;;; canonicalizing safe-under? (guards.lisp) rejects every one and still admits
;;; the legitimate reads. Deterministic: only verdicts are printed, never the
;;; absolute fixture paths. Requires Rusty ≥0.42.0 (file-symlink?/file-realpath).

(load "wuwei.lisp")
(load "demo-tools.lisp")
(load "guards.lisp")

;; ── fixture: box/ with symlinks escaping to outside/ ────────────────────────
(define ROOT "/tmp/wuwei-guardtest")
(define BOX  (str ROOT "/box"))
(define OUT  (str ROOT "/outside"))
(shell (str "rm -rf " ROOT))
(dir-create BOX)
(dir-create OUT)
(file-write (str OUT "/secret.txt") "SECRET")
(file-write (str BOX "/notes.txt")  "legit")
(shell (str "ln -s " OUT "/secret.txt " BOX "/symlink-existing.txt"))  ; -> real outside file
(shell (str "ln -s " OUT "/gone.txt "   BOX "/symlink-dangling.txt"))  ; -> nonexistent outside
(shell (str "ln -s " OUT " "            BOX "/dirlink"))               ; -> outside directory

(define (row tag v) (println (format "~a => ~s" tag v)))

(println "── the prefix-string guard's blind spot ──")
;; The OLD guard: does the path string start with the box? A symlink leaf passes.
(define (prefix-guard p) (and (string? p) (string-starts-with? p (str BOX "/"))))
(row "prefix-guard admits a symlink leaf " (prefix-guard (str BOX "/symlink-existing.txt")))

(println "")
(println "── safe-under? resolves the real location first ──")
(row "legit file (real, in box)         " (safe-under? BOX (str BOX "/notes.txt")))
(row "legit NEW file (not yet created)  " (safe-under? BOX (str BOX "/fresh.txt")))
(row "symlink -> existing outside file  " (safe-under? BOX (str BOX "/symlink-existing.txt")))
(row "DANGLING symlink -> outside       " (safe-under? BOX (str BOX "/symlink-dangling.txt")))
(row "write through a symlinked dir     " (safe-under? BOX (str BOX "/dirlink/pwned.txt")))
(row "dotdot traversal                  " (safe-under? BOX (str BOX "/../outside/secret.txt")))
(row "absolute escape                   " (safe-under? BOX "/etc/passwd"))

(println "")
(println "── end to end through the wuwei gate ──")
(deftool-spec read-file '((path string)) '(file-read) (under-guard BOX) '())
(define REG (list read-file))
(row "gate: legit read (ok)             " (gated-dispatch REG "read-file" (str BOX "/notes.txt")))
(row "gate: symlink read (rejected)     " (gated-dispatch REG "read-file" (str BOX "/symlink-existing.txt")))
(row "gate: dangling symlink (rejected) " (gated-dispatch REG "read-file" (str BOX "/symlink-dangling.txt")))

;; A 2-arg WRITE tool, gating on the first arg (the path) via the same
;; variadic under-guard. Pins that a write whose path traverses a symlinked
;; DIRECTORY component is refused end-to-end — the read-only rows above only
;; exercise a symlink LEAF on a 1-arg tool. Raw-arg is "path | content".
(deftool-spec write-file '((path string) (content string)) '(file-write) (under-guard BOX) '())
(define WREG (list write-file))
(row "gate: legit write (ok)            " (gated-dispatch WREG "write-file" (str BOX "/fresh.txt | ok")))
(row "gate: write thru symlinked dir    " (gated-dispatch WREG "write-file" (str BOX "/dirlink/pwned.txt | HACKED")))
(row "  outside stayed untouched?       " (not (file-exists? (str OUT "/pwned.txt"))))

(shell (str "rm -rf " ROOT))
(println "")
(println "guards-test: done")
