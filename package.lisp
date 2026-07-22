;; Rusty package manifest — format defined by pkg.lisp in the Rusty repo
;; (github.com/TheLakeMan/rusty). A package is any git repo with this file at
;; its root. To install (Rusty's pkg.lisp must be loaded first):
;;
;;   (load "pkg.lisp")
;;   (pkg-install "https://github.com/TheLakeMan/wuwei")   ; clone + auto-lock
;;   (pkg-load "wuwei")                                     ; gate + guards
;;
;; Pure Lisp on Rusty (>= 0.78.1, for file-hardlink? in guards.lisp's confinement
;; guard; and safe-call-with-spec behind certify-boot). No package deps.
;; `main` is wuwei-pkg.lisp, NOT wuwei.lisp: a package is loaded
;; from an arbitrary working directory and Rusty's `load` is CWD-relative, so the
;; entry loads its siblings (wuwei.lisp + guards.lisp) by absolute path.
((name "wuwei")
 (version "0.2.3")
 (main "wuwei-pkg.lisp"))
