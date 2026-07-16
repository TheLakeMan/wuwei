;;; net-guards-test.lisp — the userinfo escape, and host-allowed? closing it.
;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; The network twin of guards-test.lisp. A URL-string prefix guard has the same
;;; defect the path-prefix guard had, and a nastier one: everything before an "@"
;;; in a URL's authority is a LABEL, not a destination — so
;;; "https://api.good.com@evil.com/" starts with the allowed prefix and goes to
;;; evil.com. This test plants every such trick and shows the prefix guard waving
;;; them through while host-allowed? parses the host the way the network will.
;;;
;;; Deterministic, offline, no LLM: NOTHING here makes a network request. The
;;; gate rejects before the tool body runs, which is the whole point — and the
;;; one allowed call is proven to reach the body via a stub, not a socket.

(load "wuwei.lisp")
(load "guards.lisp")

(define (row tag v) (println (format "~a => ~s" tag v)))
(define ALLOWED (list "api.good.com" "*.cdn.good.com"))

(println "── what the request will actually reach ──")
(row "plain host                        " (url-host "https://api.good.com/v1/x"))
(row "userinfo label before @           " (url-host "https://api.good.com@evil.com/steal"))
(row "two @s: the LAST one wins         " (url-host "https://a@b@evil.com/steal"))
(row "port is not part of the host      " (url-host "https://api.good.com:8443/x"))
(row "case folds (DNS is insensitive)   " (url-host "https://API.Good.COM/x"))
(row "trailing dot is the same name     " (url-host "https://api.good.com./x"))
(row "query string is not the host      " (url-host "http://evil.com/?u=https://api.good.com"))
(row "IPv6 keeps its brackets           " (url-host "http://[::1]:8080/x"))
(row "no scheme: we do not guess        " (url-host "api.good.com/x"))
(row "scheme-relative: still no scheme  " (url-host "//api.good.com/x"))
(row "not a string                      " (url-host 42))

(println "")
(println "── the prefix-string guard's blind spot ──")
;; The tempting guard: does the URL start with the allowed origin?
(define (prefix-guard u)
  (and (string? u) (string-starts-with? u "https://api.good.com")))
(row "prefix-guard admits userinfo trick" (prefix-guard "https://api.good.com@evil.com/steal"))
(row "prefix-guard admits suffix trick  " (prefix-guard "https://api.good.com.evil.com/steal"))

(println "")
(println "── host-allowed? parses first, then decides ──")
(row "legit allowed host                " (host-allowed? ALLOWED "https://api.good.com/v1/x"))
(row "userinfo trick -> evil.com        " (host-allowed? ALLOWED "https://api.good.com@evil.com/steal"))
(row "suffix trick -> evil.com          " (host-allowed? ALLOWED "https://api.good.com.evil.com/x"))
(row "allowed host in the QUERY only    " (host-allowed? ALLOWED "http://evil.com/?u=https://api.good.com"))
(row "mixed case is still allowed       " (host-allowed? ALLOWED "https://API.GOOD.COM/x"))
(row "trailing dot is still allowed     " (host-allowed? ALLOWED "https://api.good.com./x"))
(row "a port does not change the host   " (host-allowed? ALLOWED "https://api.good.com:8443/x"))
(row "scheme-relative: no host to check " (host-allowed? ALLOWED "//api.good.com/x"))
(row "off-allowlist host                " (host-allowed? ALLOWED "https://evil.com/x"))

(println "")
(println "── subdomains are opt-in, never implied ──")
;; A bare entry does NOT admit subdomains: if an attacker can get one of yours,
;; an implicit default would hand them the fence.
(row "sub of a bare entry: NOT allowed  " (host-allowed? ALLOWED "https://evil.api.good.com/x"))
(row "*.cdn.good.com admits a subdomain " (host-allowed? ALLOWED "https://img.cdn.good.com/x"))
(row "*.cdn.good.com admits deeper subs " (host-allowed? ALLOWED "https://a.b.cdn.good.com/x"))
(row "*.cdn.good.com does NOT admit apex" (host-allowed? ALLOWED "https://cdn.good.com/x"))
(row "...nor a lookalike of it          " (host-allowed? ALLOWED "https://xcdn.good.com/x"))

(println "")
(println "── end to end through the wuwei gate ──")
;; A stub body: the test must never touch the network. It returns a marker, so
;; an "ok" verdict proves the body actually ran (the gate let it through) and a
;; rejection proves it never did.
(deftool http-get (url)
  "Fetch a URL"
  (str "FETCHED " url))
(deftool-spec http-get '((url string)) '() (host-guard ALLOWED) '())
(define REG (list http-get))
(row "gate: allowed host (ok)           " (gated-dispatch REG "http-get" "https://api.good.com/v1/x"))
(row "gate: userinfo trick (rejected)   " (gated-dispatch REG "http-get" "https://api.good.com@evil.com/steal"))
(row "gate: off-allowlist (rejected)    " (gated-dispatch REG "http-get" "https://evil.com/x"))

(println "")
(println "net-guards-test: done")
