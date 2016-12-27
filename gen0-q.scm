(require "gen0" &private)
(require "gen-testutils")
(require "io")

;;--------------------------------
;; utilities
;;--------------------------------

(define (p1-0 text)
  (form-set-indices 0 (p1 text)))

;; Compile text, returning final env (or error).
;;
(define (text-to-env text ?env ?allow-nodes)
  (c0-block-cc env (pN text)
               (lambda (env nodes)
                 (if (and nodes
                          (not allow-nodes)
                          (not (eq? [(IString "")] nodes)))
                     (sprintf "UNEXPECTED NODES: '%q'" nodes)
                     env))))


;;--------------------------------
;; tests
;;--------------------------------


(define `flag-args
  [ (PString 0 "F") (PSymbol 2 "&private") (PSymbol 3 "&global")
    (PSymbol 2 "bar") ])

(expect 0 (scan-flags flag-args 0))
(expect 3 (scan-flags flag-args 1))
(expect 3 (scan-flags flag-args 2))
(expect 3 (scan-flags flag-args 3))
(expect 4 (scan-flags flag-args 4))

(expect ["&private" "&global"]  (get-flags flag-args 1))
(expect ["&global"]             (get-flags flag-args 2))
(expect flag-args               (skip-flags flag-args 0))
(expect [(PSymbol 2 "bar") ]    (skip-flags flag-args 1))
(expect [(PSymbol 2 "bar") ]    (skip-flags flag-args 2))


(expect (ILocal 3 0) (c0-local ".3"  (EMarker ".") nil))
(expect (ILocal 3 1) (c0-local ".3"  (EMarker "..") nil))
(expect (ILocal 3 1) (c0-local "..3" (EMarker "...") nil))
(expect (ILocal 3 2) (c0-local ".3"  (EMarker "...") nil))


;;--------------------------------
;; c0-xxxx tests
;;--------------------------------


;; PString
(expect (c0-ser "\" x \"")
        " x ")


;; PSymbol: global data variable
(expect (c0-ser "d!0!")
        "{D!0!}")

;; PSymbol: global function variable
(expect (c0-ser "f!0!")
        "(.value F!0!)")

;; PSymbol: undefined variables
(expect (c0-ser "foo")
        "!(PError 1 'undefined variable \\'foo\\'')")


;; c0-block

(expect (c0-ser "\"x\" v")
        "(IBlock x,{V})")


;; PList: (functionvar ...)

(expect (c0-ser "(f!0! 1 2)")
        "(F!0! 1,2)")
(expect (c0-ser "(f 1)")
        "!(PError 2 '\\'f\\' accepts 2 arguments, not 1')")
(expect (c0-ser "(f)" (text-to-env "(declare (f a ?b))"))
        "!(PError 2 '\\'f\\' accepts 1 or 2 arguments, not 0')")
(expect (c0-ser "(f)" (text-to-env "(declare (f a ?b ...))"))
        "!(PError 2 '\\'f\\' accepts 1 or more arguments, not 0')")
(expect (c0-ser "(f)" (text-to-env "(declare (f a b ...))"))
        "!(PError 2 '\\'f\\' accepts 2 or more arguments, not 0')")
(expect (c0-ser "(f)" (text-to-env "(declare (f a ?b ?c))"))
        "!(PError 2 '\\'f\\' accepts 1 or 2 or 3 arguments, not 0')")


;; PList: (inlinefunc ...) and env-rewinding

(expect (c0-ser "(f 1)" (append
                         (hash-bind "g" (EVar "newG" "."))
                         (hash-bind "f" (EFunc NoGlobalName "."
                                               ["a" (p1 "(filter a g)")]))
                         (hash-bind "g" (EVar "oldG" "."))))
        "(.filter 1,{oldG})")

;; PList: (datavar ...)

(expect (c0-ser "(d!0! 7)")
        "(^Y {D!0!},7)")

;; PList: (record ...)

(expect (il-ser (c0-record base-env
                           (PSymbol 0 "CA")
                           [ (PString 1 "1") (PString 1 "2") ]
                           "S L"
                           "!:D0"))
        "!:D0 1 2")

(expect (il-ser
         (c0-ctor (hash-bind "Ctor" (ERecord "S L" "." "!:T0"))
                  (PSymbol 0 "Ctor")
                  "S L"))
        "`!:T0 (^d {1}) {2}")

(expect (c0-ser "C" (hash-bind "C" (ERecord "S W L" "." "!:T0")))
        "`!:T0 (^d {1}) {2} {3}")


;; PList: (<builtin> ...)  with base-env

(expect (c0-ser "(or 7)" base-env)
        "(.or 7)")
(expect (c0-ser "(if 1)")
        "!(PError 2 '\\'if\\' accepts 2 or 3 arguments, not 1')")
(expect (c0-ser "(if 1 2 3 4)")
        "!(PError 2 '\\'if\\' accepts 2 or 3 arguments, not 4')")
(expect (c0-ser "(bar)")
        "!(PError 2 'undefined symbol: \\'bar\\'')")
(expect (c0-ser "()")
        "!(PError 1 'missing function/macro name')")

;; PList: (arg ...)

(expect (c0-ser "(var 7)"
                (lambda-env [(PSymbol 0 "var")] nil))
        "(^Y {1},7)")

(begin
  (define (test-xmacro form)
    (PString 1 "hi"))
  (define `test-xm-env
    (hash-bind "var" (EXMacro (global-name test-xmacro) "i")))

  (expect (c0-ser "(var 7)" test-xm-env)
          "hi"))

;; PList: (lambda NAMES BODY)

;; lambda-env
(expect (lambda-env [(PSymbol 1 "b")]
                    (lambda-env [(PSymbol 1 "a")]
                                nil))
        (append (hash-bind LambdaMarkerKey (EMarker ".."))
                (hash-bind "b" (EArg "..1"))
                (hash-bind LambdaMarkerKey (EMarker "."))
                (hash-bind "a" (EArg ".1"))))

(let ((env (lambda-env (pN "a b c e f g h i j k") nil)))
  (expect (word 1 env)
          (hash-bind LambdaMarkerKey (EMarker ".")))
  (expect (hash-get "a" env)
          (EArg ".1"))
  (expect (hash-get "i" env)
          (EArg ".8"))
  (expect (hash-get "j" env)
          (EIL (IBuiltin "call" [(IString "^n") (IString 1) (IVar 9)])))
  (expect (hash-get "k" env)
          (EIL (IBuiltin "call" [(IString "^n") (IString 2) (IVar 9)]))))

(expect (EIL (IBuiltin "foreach" [(IString "N") (IString 3) (IVar "^v")]))
        (hash-get "..." (lambda-env (pN "a b ...") nil)))
(expect (EIL (IBuiltin "foreach" [(IString "N") (IString 3) (IVar "^v")]))
        (hash-get "r" (lambda-env (pN "a b ...r") nil)))
(expect (EIL (IBuiltin "wordlist" [(IString 2) (IString 999999) (IVar "9")]))
        (hash-get "..." (lambda-env (pN "a b c d e f g h i ...") nil)))
(expect (EIL (IVar 9))
        (hash-get "..." (lambda-env (pN "a b c d e f g h ...") nil)))
(expect (EIL (IVar 9))
        (hash-get "r" (lambda-env (pN "a b c d e f g h ...r") nil)))

;; local variable referencing arg 9
(expect (c0-ser "X" (lambda-env (pN "a a a a a a a a X Y")
                                base-env))
        "(.call ^n,1,{9})")

(expect (c0-ser "(lambda (a) v)")
        "`{V}")

(expect (c0-ser "(lambda (a b) a b)")
        "`(IBlock {1},{2})")

(foreach SCAM_DEBUG "-" ;; avoid upvalue warning
         (expect (c0-ser "(lambda (a) (lambda (b) a b))")
                 "``(IBlock {1^1},{1})"))

;; PSymbol: macro  (uses c0-lambda)
(begin
  (define `macro-inln
    [ [ "a" "b" ] (p1-0 "(word a b)") ])
  (define `macro-env
    (hash-bind "M" (EFunc NoGlobalName "." macro-inln)))

  (expect (il-ser (c0-macro macro-env (PSymbol 0 "M") macro-inln))
          "`(.word {1},{2})"))


;; PSymbol: builtin  (uses c0-lambda)

(expect (il-ser (c0-builtin base-env "word" "2 or 1"))
        "`(.word {1},{2})")
(expect (il-ser (c0-builtin base-env "or" "%"))
        "`(^apply or,{^av})")

;; ': quote

(expect (c0-ser "'(joe bob)")
        (p1 " (joe bob)"))

;;
;; `: quasi-quote
;;
;; A quoted expression *evaluates* to the AST for the quoted expression:
;;    ((c1 (c0 ["`" AST]))) -> AST

(define (cqq text)
  (c0-ser text (append (hash-bind "sym" (EIL (IString "SYM")))
                       (hash-bind "var" (EVar "VAR" "."))
                       ;; args = [`a `b]
                       (hash-bind "args" (EIL (IString [(PSymbol 1 "a")
                                                       (PSymbol 2 "b")]))))))

(expect (c0 (p1-0 "`x") nil)
        (IString (p1-0 "x")))

(expect (cqq "`,sym")
        "SYM")


(expect (cqq "`,var")
        "{VAR}")

(expect (cqq "`(a 1 ,var)")
        (concat (PList 2 [ (PSymbol 3 "a") (PString 5 1) ]) " (^d {VAR})"))



;; nested quote/unquote
(begin
  (define `(dd node) (concat "(^d " node ")"))
  (define (cc ...nodes) (IConcat nodes))

  ;; Some demote operations are deferred until run-time, some are already
  ;; applied to literal values.
  (expect (subst "TOP"   (PList 2 ["(A)"])
                 "(A)"   (dd (PQQuote 4 "(B)"))
                 "(B)"   (PList 5 ["(C1)" "(C2)" "(C3)"])
                 "(C1)"  [(PSymbol 6 "a")]
                 "(C2)"  [(PUnquote 8 (PSymbol 9 "var"))]
                 "(C3)"  (dd (PUnquote 11 "{VAR}"))
                 "TOP")
          (cqq "`( `(a ,var ,,var))")))

;; errors

(expect (c0-ser ",a")
        "!(PError 1 'unquote (,) outside of a quasiquoted (`) form')")
(expect (cqq "`)")
        "!(PError 2 ')')")
(expect (cqq "`,)")
        "!(PError 3 ')')")


;; splicing

(expect (cqq "`(1 ,@args 2)")
        (PList 2 [(PString 3 1) (PSymbol 1 "a") (PSymbol 2 "b") (PString 8 2)]))

(expect (cqq "`(1 ,@var 2)")
        (PList 2 [ (PString 3 1) "{VAR}" (PString 8 2) ]))

;;
;; declare & define
;;

(define env0 (hash-bind "x" "V x"))

(expect (text-to-env "(declare var)")
        (hash-bind "var" (EVar (gen-global-name "var" nil) ".")))
(expect (text-to-env "(declare var &private)")
        (hash-bind "var" (EVar (gen-global-name "var" nil) "p")))

;; declare FUNC
(expect (text-to-env "(declare (fn a b))")
        (hash-bind "fn" (EFunc (gen-global-name "fn" nil) "." [["a" "b"]])))
(expect (text-to-env "(declare (fn a b) &private)")
        (hash-bind "fn" (EFunc (gen-global-name "fn" nil) "p" [["a" "b"]])))

;; declare errors
(expect (c0-ser "(declare)")
        "!(PError 2 'missing FORM in (declare FORM ...); expected a list or symbol')")
(expect (c0-ser "(declare foo 7)")
        "!(PError 6 'too many arguments to (declare ...)')")
(expect (c0-ser "(declare (1 a))")
        "!(PError 5 'invalid NAME in (declare (NAME...)); expected a symbol')")


;; define VAR
(p1-block-cc
 "(define x 1) (info x)"
 (lambda (env sil)
   (expect env (hash-bind "x" (EVar (xns "~x") ".")))
   (expect sil (xns "(IBlock (^set ~x,1),(.info {~x}))"))))


;; define FUNC
(expect (c0-ser "(define (f a ?b) (join a b))")
        (xns "(^fset ~f,`(.join {1},{2}))"))

(expect (text-to-env "(define (f a) a)" nil 1)
        (xns (hash-bind "f" (EFunc "~f" "." [["a"]]))))

(expect (c0-ser "(define (word a) a)")
        "!(PError 4 'cannot redefine built-in function \\'word\\'')")

;; define compound macro
(expect (text-to-env "(define `(M a) (concat a a))")
        (hash-bind "M" (EFunc NoGlobalName "." ["a" (p1-0 "(concat a a)")])))

(expect (text-to-env "(define `(M a) &private (concat a a))")
        (hash-bind "M" (EFunc NoGlobalName "p"  ["a" (p1-0 "(concat a a)")])))

;; define symbol macro
(expect (text-to-env "(define `I 7)" env0)
        (hash-bind "I" (ESMacro (PString 0 7) ".") env0))
(expect (text-to-env "(define `I &private 7)" env0)
        (hash-bind "I" (ESMacro (PString 0 7) "p") env0))

;; (define ...) errors

(expect nil (check-optional-args [(PSymbol 0 "a") (PSymbol 0 "b")]))
(expect nil (check-optional-args [(PSymbol 0 "?a") (PSymbol 0 "?b")]))
(expect nil (not (check-optional-args [(PSymbol 0 "?a") (PSymbol 0 "b")])))
(expect nil (not (check-optional-args [(PSymbol 0 "...a") (PSymbol 0 "b")])))


(expect (c0-ser "(define)")
        "!(PError 2 'missing FORM in (define FORM ...); expected a list or symbol')")
(expect (c0-ser "(define `1)")
        "!(PError 5 'invalid FORM in (define `FORM ...); expected a list or symbol')")
(expect (c0-ser "(define `M &inline 1)")
        "!(PError 5 ''&inline' does not apply to symbol definitions')")
(expect (c0-ser "(define X &inline 1)")
        "!(PError 4 ''&inline' does not apply to symbol definitions')")
(expect (c0-ser "(define `(m ...x) x)")
        "!(PError 8 'macros cannot have optional parameters')")
(expect (c0-ser "(define (m ...x) &inline x)")
        "!(PError 7 'inline functions cannot have optional parameters')")
(expect (c0-ser "(define (f ...x z) x)")
        "!(PError 9 'non-optional parameter after optional one')")
(expect (c0-ser "(define (f ?a x) x)")
        "!(PError 9 'non-optional parameter after optional one')")


;; define and use symbol macro

(expect (c0-ser "(define `X 3) X")
        "3")

;; define and use compound macro

(expect (c0-ser "(define `(M a) (info a) 3) (M 2)")
        "(IBlock (.info 2),3)")

(expect (c0-ser "(define `(M a) (info a)) M")
        "`(.info {1})")


;; define inline FUNC
(let ((env (text-to-env (concat "(define (f a b) &inline (join a b))"
                                "(define (g x) &inline (info x))")
                        nil 1)))
  (expect (hash-get "g" env)
          (EFunc (gen-global-name "g" nil)
                 "."
                 ["x" (p1-0 "(info x)")]))
  (expect (hash-get "f" env)
          (EFunc (gen-global-name "f" nil)
                 "."
                 ["a b" (p1-0 "(join a b)")])))


;; define and use inline FUNC
(expect (c0-ser "(define (f a b) &inline (join a b))  (f 1 2)")
        (xns "(IBlock (^fset ~f,`(.join {1},{2})),(.join 1,2))"))


;;
;; Macro & inline function exporting/importing.
;;

(define (canned-MIN name)
  (cond
   ((eq? "D/M" name) "(declare X &private) (declare x)")
   ((eq? "M" name) "(declare X &private) (declare x)")
   ((eq? "F" name) "(define X &private 1) (define (f) &inline X)")
   ((eq? "CM" name) "(define `(F) &private 3) (define `(G) (F))")
   ((eq? "SM" name) "(define `A &private 7) (define `B A)")
   (else (expect (concat "Bad module: " name) nil))))

(define (canned-read-file name)
  (env-export (text-to-env (canned-MIN name) nil 1)))

(declare (mod-find name))


(let-global
 ;; This overrides (!) the function for looking up modules.
 ((mod-find (lambda (m f) m))
  (read-file canned-read-file)
  (read-lines (lambda (file a b) (wordlist a b (split "\n" (canned-read-file file))))))
 ;; (require MOD)

 (expect (c0-ser "(require \"D/M\")")
         "(^require M)")

 (expect (text-to-env "(require \"M\")" nil 1)
         (hash-bind "x" (EVar (gen-global-name "x" nil) "i")))

 (expect (c0-ser "(require \"D/M\" \"xyz\")")
         "!(PError 0 'too many arguments to require')")

 ;; (require MOD &private)

 (expect (text-to-env "(require \"M\" &private)" nil 1)
         (append (hash-bind "x" (EVar (gen-global-name "x" nil) "."))
                 (hash-bind "X" (EVar (gen-global-name "X" nil) "p"))))

 ;; Verify that IMPORTED inline functions & macros are expanded in their
 ;; original environment (read from their MIN files' exports) so they can
 ;; see private members.

 ;; IMPORTED inline function
 (expect (c0-ser "(require \"F\") (f)")
         (xns "(IBlock (^require F),{~X})"))

 ;; IMPORTED compound macro
 (expect (c0-ser "(require \"CM\") (G)")
         "(IBlock (^require CM),3)")

 ;; IMPORTED symbol macro
 (expect (c0-ser "(require \"SM\") B")
         "(IBlock (^require SM),7)"))

;; RECURSIVE INLINE FUNCTION: we should see one level of expansion where it
;; is used.

(expect
 (c0-ser "(define (f a b) &inline (if a b (f b \"\"))) (f 1 2)")
 (xns "(IBlock (^fset ~f,`(.if {1},{2},(~f {2},))),(.if 1,2,(~f 2,)))"))
