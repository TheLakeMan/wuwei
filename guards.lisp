;;; guards.lisp — canonicalizing path guards for wuwei preconditions.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; A precondition that checks a path *string* ("starts with /box/") is defeated
;;; by a LINK inside the box pointing out: every filesystem builtin FOLLOWS
;;; symlinks, so the effect lands outside the fence. safe-under? resolves the
;;; REAL location first, using Rusty's no-follow primitives:
;;;   file-symlink?  (≥0.42.0) — lstat: is the path itself a symlink (incl. dangling)?
;;;   file-realpath  (≥0.42.0) — canonicalize: real absolute path, or Nil if unresolvable.
;;;   file-hardlink? (≥0.78.1) — lstat: a non-dir, non-symlink leaf, >1 name?
;;;
;;; It rejects any symlink LEAF outright (a confinement guard never writes/reads
;;; through one); rejects a HARDLINKED leaf too — a second name on the same inode
;;; may lie outside the box, and unlike a symlink a hardlink has no separate
;;; canonical path for file-realpath to expose (it resolves to the in-box name),
;;; so nlink is the only signal; and requires the canonical path — or, for a
;;; not-yet-created file, its canonical parent — to sit under the canonical box.
;;; Canonicalizing the parent is what catches a symlink in a MIDDLE path component.
;;;
;;; HONEST SCOPE: this closes every *planted* symlink and every hardlinked leaf.
;;; The hardlink check is CONSERVATIVE — it refuses a multiply-linked leaf even
;;; when the sibling name is itself inside the box (nlink can't say where the
;;; other name lives). It does NOT close a live TOCTOU race (a component swapped
;;; between check and open) or other inode-level games — that is a kernel job.
;;; For a hostile filesystem, run wuwei inside real OS isolation too.

;; everything up to the last "/"; "." when there is no slash, "/" at root.
(define (path-parent p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) ".")
          ((equal? (substring p i (+ i 1)) "/")
           (if (= i 0) "/" (substring p 0 i)))
          (else (loop (- i 1))))))

;; everything after the last "/".
(define (path-basename p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) p)
          ((equal? (substring p i (+ i 1)) "/")
           (substring p (+ i 1) (string-length p)))
          (else (loop (- i 1))))))

;; rp equal to, or strictly inside, base — both canonical absolute paths.
(define (path-under? base rp)
  (or (equal? rp base) (string-starts-with? rp (str base "/"))))

;; The guard. box = a directory path (trailing slash optional).
(define (safe-under? box path)
  (let ((bc (file-realpath box)))              ; canonical box (must exist)
    (and (string? path)
         bc
         (not (file-symlink? path))            ; never trust a symlink leaf
         (not (file-hardlink? path))           ; nor a hardlinked leaf (sibling may escape)
         (let ((rp (if (file-exists? path)
                       (file-realpath path)     ; existing: resolve the whole path
                       (let ((pc (file-realpath (path-parent path))))
                         (and pc (str pc "/" (path-basename path)))))))
           (and (string? rp) (path-under? bc rp))))))

;; Adapt safe-under? into a precondition of ANY tool arity, gating on the FIRST
;; argument (the path) and ignoring the rest. Correct for a single-path tool —
;; read-file, and write-file whose 2nd arg is DATA written into the already-gated
;; path, not a path itself. Pairs with deftool-spec exactly like in-box? did:
;;   (deftool-spec read-file '((path string)) '(file-read) (under-guard BOX) '())
(define (under-guard box)
  (lambda (p . rest) (safe-under? box p)))

;; For a tool that takes MORE THAN ONE path argument (e.g. copy src -> dst),
;; under-guard would confine only src and leave dst free. A guard can't tell a
;; path arg from a data arg, so the author names the 0-based positions that are
;; paths; EVERY one must sit under the box. Blindly gating all args is wrong —
;; it would reject a write's content string — which is why this is explicit.
;;   (deftool-spec copy '((src string) (dst string)) '(file-read file-write)
;;                 (under-guard-paths BOX '(0 1)) '())
(define (under-guard-paths box positions)
  (lambda args
    (all? (lambda (i) (safe-under? box (nth args i))) positions)))


;;; ── Host allowlists — the same shape, one layer out ─────────────────────────
;;;
;;; A precondition that checks a URL *string* ("starts with https://api.good.com")
;;; has the same defect the path-prefix guard had, and it is not a subtle one:
;;;
;;;     https://api.good.com@evil.com/steal
;;;
;;; That URL starts with "https://api.good.com". The request goes to **evil.com**.
;;; Everything before an "@" in the authority is *userinfo* — a label, not a
;;; destination. It is the symlink of URLs: the string says one thing, the effect
;;; lands somewhere else. Its cousins:
;;;
;;;     https://good.com.evil.com/     — starts-with "good.com" passes; host is evil.com
;;;     http://evil.com/?u=good.com    — a "contains" guard passes; host is evil.com
;;;
;;; So: parse the host the way the network will read it, then match it. Same rule
;;; as safe-under? — resolve what will ACTUALLY be reached before deciding.
;;;
;;; Be precise about WHERE the danger is, because it is easy to oversell this.
;;; A string guard fails OPEN on the URLs above: it says yes, and the request
;;; goes to evil.com. That is the hole. A guard that parses the authority at all
;;; — even badly — fails CLOSED on them: a mangled "api.good.com@evil.com"
;;; matches no allowlist entry, so it is rejected. Parsing *correctly* is
;;; therefore not what saves you from the attack; it is what keeps the fence
;;; honest while still admitting the legitimate URLs (userinfo, ports, mixed
;;; case, trailing dots) that a sloppy parser would reject for the wrong reason.
;;; The security claim here is small and exact: **match on the parsed host, never
;;; on the URL string.**
;;;
;;; HONEST SCOPE, and it matters as much as the guard does:
;;;   - This fences the URL you hand it. It does NOT follow the request. An
;;;     allowed host that answers 302 -> https://evil.com/ lands off-allowlist,
;;;     and nothing here can see that: the redirect happens inside the HTTP
;;;     client, after the gate said yes. Same shape as the symlink TOCTOU —
;;;     a runtime job, not a language one. Disable redirects in the tool
;;;     (`curl` without -L), or re-gate every hop.
;;;   - DNS is not fenced either: an allowed name that resolves to an attacker's
;;;     address (rebinding, poisoned resolver, hostile /etc/hosts) still passes.
;;;     The name is what's checked, never the address it becomes.
;;;   - ASCII hosts only. IDN/punycode is out of scope: homograph domains
;;;     (gооgle.com in Cyrillic) are a display problem this does not solve.
;;;   - Ports are not fenced: good.com:8443 is the same HOST as good.com. If a
;;;     port matters to you, that is a different guard.

;; ASCII case folding — hostnames are ASCII by definition (that's what punycode
;; is for), and DNS is case-insensitive, so this is exactly the right fold.
(define *guard-upper* "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
(define *guard-lower* "abcdefghijklmnopqrstuvwxyz")
(define (char-downcase c)
  (let ((i (string-first-index *guard-upper* c)))
    (if i (substring *guard-lower* i (+ i 1)) c)))
(define (ascii-downcase s)
  (string-append-list (map char-downcase (string->list s))))

(define (string-ends-with? s suffix)
  (let ((ls (string-length s)) (lf (string-length suffix)))
    (and (>= ls lf) (equal? (substring s (- ls lf) ls) suffix))))

;; Cut s at the first occurrence of any delimiter in `chars` (list of 1-char
;; strings); the authority ends at whichever comes first.
(define (cut-at s chars)
  (let loop ((i 0))
    (cond ((>= i (string-length s)) s)
          ((string-member? (substring s i (+ i 1)) chars) (substring s 0 i))
          (else (loop (+ i 1))))))

;; The HOST a URL actually reaches: lowercase, no userinfo, no port, no trailing
;; dot. #f when there is no host we can be sure of — and being unsure is a
;; rejection, never a shrug.
(define (url-host url)
  (and (string? url)
       ;; NB substr-index returns -1 on a miss, and in Rusty ONLY #f is false —
       ;; so a bare (and i ...) accepts -1 and (substring url (+ -1 3)) happily
       ;; invents a host out of a URL that has no scheme at all. It did exactly
       ;; that here, and admitted "//api.good.com/x". Compare against 0.
       (let ((i (substr-index url "://")))
         (and (>= i 0)                             ; no scheme -> we don't guess
              (let* ((rest (substring url (+ i 3) (string-length url)))
                     ;; authority ends at the first / ? or #
                     (auth (cut-at rest (list "/" "?" "#")))
                     ;; userinfo: everything before the LAST "@" is a label.
                     ;; Last, not first — "a@b@evil.com" is evil.com.
                     (at   (string-last-index auth "@"))
                     (hp   (if at (substring auth (+ at 1) (string-length auth)) auth))
                     ;; port: [::1]:8080 keeps its brackets; host:8080 does not
                     (host (if (string-starts-with? hp "[")
                               (let ((close (string-first-index hp "]")))
                                 (if close (substring hp 0 (+ close 1)) hp))
                               (cut-at hp (list ":"))))
                     (h    (ascii-downcase host))
                     ;; "good.com." and "good.com" are the same name to DNS
                     (h2   (if (and (> (string-length h) 1) (string-ends-with? h "."))
                               (substring h 0 (- (string-length h) 1))
                               h)))
                (and (> (string-length h2) 0) h2))))))

;; One allowlist entry vs a parsed host. EXACT by default — a bare "good.com"
;; does NOT admit "anything.good.com". Subdomains are opt-in, spelled "*.good.com",
;; and that form admits subdomains ONLY (list the apex too if you want it).
;; Explicit beats convenient: if an attacker can get a subdomain of yours, an
;; implicit-subdomain default hands them the fence.
(define (host-matches? entry host)
  (let ((e (ascii-downcase entry)))
    (if (string-starts-with? e "*.")
        (let ((base (substring e 1 (string-length e))))   ; ".good.com"
          (string-ends-with? host base))
        (equal? host e))))

;; The guard. allowed = a list of host entries.
(define (host-allowed? allowed url)
  (let ((h (url-host url)))
    (and h (not (null? (filter (lambda (e) (host-matches? e h)) allowed))))))

;; Adapt into a precondition of ANY tool arity, gating on the first argument
;; (the URL) — the network twin of under-guard:
;;   (deftool-spec http-get '((url string)) '(shell) (host-guard ALLOWED) '())
(define (host-guard allowed)
  (lambda (u . rest) (host-allowed? allowed u)))
