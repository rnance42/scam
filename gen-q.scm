;; Tests for gen0

(require "core")
(require "parse")
(require "gen" &private)

;;
;; IL-related definitions
;;

(expect (String "")
        (il-concat))
(expect (String "abc")
        (il-concat [ (String "abc") ]))
(expect (String "ab")
        (il-concat [ (String "a") (String "b") ]))
(expect (Concat [ (String "ab") (Var "V") (String "cd") ])
        (il-concat [ (String "a")
                     (Concat [ (String "b") (Var "V") (String "c") ])
                     (String "d") ]))


(expect (Call "^d" [ (Var "V") ])
        (il-demote (Var "V")))
(expect (String ["a b"])
        (il-demote (String "a b")))
(expect (Var "V")
        (il-demote (Call "^u" [ (Var "V") ])))


;;
;; Environment definitions
;;

;; after, env-rewind

(expect "b c a"  (after "a" "a b c a"))
(expect "c d e"  (after "c" "a b c c d e"))
(expect ""       (after "f" "a b c d e f"))
(expect ""       (after "z" "a b c d e f"))

(expect (hash-bind "a" "asdf")
        (env-rewind-M (hash-bind "x" 1
                            (hash-bind "m" "-"
                                  (hash-bind "a" "asdf")))
                      "m"))

(expect (append
         (hash-bind LambdaMarkerKey "..")
         (hash-bind "a" "asdf"))
        (env-rewind (hash-bind "x" 1
                          (hash-bind LambdaMarkerKey ".."
                                (hash-bind "f" (EFunc "f" "." "")
                                      (hash-bind "a" "asdf"))))
                    "f"))


;; gensym

(expect "foo&"   (gensym-name "foo"))
(expect (PSymbol 0 "foo&") (gensym (PSymbol 0 "foo")))
(expect (PSymbol 0 "foo&1") (gensym (PSymbol 0 "foo")
                          (hash-bind (symbol-name (gensym (PSymbol 0 "foo")))
                                     (EVar "x" "."))))

;; gen-error

(expect (PError 12 "Msg: hello error")
        (gen-error (PString 12 "x") "Msg: %s %s" "hello" "error"))


;; env-compress

(for s [",.;[]\!1!0!11!10!021!10 !. !@#$%^&*()_+=|}{\\][/.,?><';\":`~,i x!=F!0x v!=V!0x"]
     (expect s (env-expand (env-compress s))))


;; env-export & env-import

;(expect "# Exports: vname!Vvarname,. fname|realname,.,DEFN\n"
;        (env-export
;         (append (hash-bind "vname" (EVar "varname" "."))
;                 (hash-bind "fname" (EFunc "realname" "." "DEFN")))))


(define (export-round-trip env flag filename)
  (env-import
   (env-parse [ "# comment"
                (subst "\n" "" (env-export env))
                "# F F F F F F"])
   flag
   filename))


;; import only public members

(expect (append (hash-bind "f" (EFunc "f" "i" nil))
                (hash-bind "x" (EVar "X" "i"))
                (hash-bind "a" (EFunc "fa" "iMOD" ["a b" (PSymbol 0 "a")]))
                (hash-bind "m" (ESMacro "Q 1" "iMOD"))
                (hash-bind "a:n\n,x" (EVar "xyz" "i")))

        (export-round-trip
         (append (hash-bind "f" (EFunc "f" "." nil))
                 (hash-bind "x" (EVar "X" "."))
                 (hash-bind "a" (EFunc "fa" "." ["a b" (PSymbol 0 "a")]))
                 (hash-bind "g" (EFunc "g" "p" nil))  ;; private
                 (hash-bind "g" (EFunc "g" "i" nil))  ;; imported
                 (hash-bind "m" (ESMacro "Q 1" "."))
                 (hash-bind "a:n\n,x" (EVar "xyz" ".")))
         ""
         "MOD"))


;; import public AND private members

(expect (append (hash-bind "f" (EFunc "f" "." nil))
                (hash-bind "x" (EVar "X" "."))
                (hash-bind "a" (EFunc "a" "i" ["a b" (PSymbol 0 "a")]))
                (hash-bind "g" (EFunc "g" "p" nil))
                (hash-bind "g" (ESMacro "g" "i"))  ;; imported
                (hash-bind "a:n\n,x" (EVar "xyz" ".")))

        (export-round-trip
         (append (hash-bind "f" (EFunc "f" "." nil))
                 (hash-bind "x" (EVar "X" "."))
                 (hash-bind "a" (EFunc "a" "i" ["a b" (PSymbol 0 "a")]))
                 (hash-bind "g" (EFunc "g" "p" nil))  ;; private
                 (hash-bind "g" (ESMacro "g" "i"))    ;; imported macro
                 (hash-bind "a:n\n,x" (EVar "xyz" ".")))
         1
         "File Name.min"))

;; base-env and resolve

(expect (EVar "^av" "b")
        (resolve (PSymbol 0 "*args*") base-env))

(expect (EVar "D!0!" nil)
        (resolve (PSymbol 0 "d!0!") (hash-bind "d!0!" (EVar "D!0!" nil))))
