;;--------------------------------
;; escaping tests
;;--------------------------------

(require "core")
(require "escape" &private)

(expect "()"                    (protect-arg "()"))
(expect "(!1. )"                (protect-arg "(!1. )"))
(expect "(,)"                   (protect-arg "(,)"))
(expect "$(if ,,(,),)"          (protect-arg "(,),"))
(expect "$(\\R)$(\\L)"          (protect-arg ")("))
(expect "()$(\\L)"              (protect-arg "()("))
(expect "$(if ,,(a),(,)$(\\L))"  (protect-arg "(a),(,)("))

(expect "" (findstring "!" (check-balance "a(b)c()")))
(expect "" (findstring "!" (check-balance "()")))
(expect "!" (findstring "!" (check-balance "(")))
(expect "!" (findstring "!" (check-balance ")")))
(expect "!" (findstring "!" (check-balance "a(b)c(")))
(expect "!" (findstring "!" (check-balance "a)b)c")))
(expect "!" (findstring "!" (check-balance "a(b(c")))

(expect "$  b"     (protect-ltrim " b"))
(expect "$ \t"     (protect-ltrim "\t"))
(expect "x y "     (protect-ltrim "x y "))

(expect "$(if ,,\na)"  (protect-trim "\na"))
(expect "$(if ,,a\n)"  (protect-trim "a\n"))
(expect "a\nb"         (protect-trim "a\nb"))

(expect "x$(\\H)"     (protect-lhs "x#"))
(expect "$(if ,,x=)"  (protect-lhs "x="))

(expect "abc\ndef" (protect-define "abc\ndef"))
(expect "$ define\n$ endef extra\\$ \n\\$ "
        (protect-define "define\nendef extra\\\n\\"))


(print "escape ok")
