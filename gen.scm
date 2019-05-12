;--------------------------------------------------------------
;; gen : Environment and IL types; code generation utilities
;;--------------------------------------------------------------

(require "core.scm")
(require "parse.scm")

;; Globals used in code generation
;; -------------------------------

;; *compile-subject* contains the penc-encoded SCAM source being compiled
(declare *compile-subject* &public)

;; *compile-file* is the name of the source file being compiled.
(declare *compile-file* &public)

;; When true, the compiler operates in boot mode: no builtin modules will be
;; used, and globals in generated code will be prefixed with "~".
(define *is-boot* &public nil)


;; IL Records
;; ----------
;;
;; "IL" is an intermediate language encoded as records of the IL data type,
;; defined below.  IArg, IFuncall, and ILamda records embody the untyped
;; lambda calculus, but with multiple positional arguments to each function.
;; Further terms deal with the "primordial" data types and functionality of
;; the target VM, GNU Make 3.81, wherein all values (including functions)
;; are strings.  A `nil` value in IL represents an empty string.
;;
;; IArg: References a local variable -- a positional argument NDX (1...N) to
;;     some parent lambda, or "=AUTO" where AUTO is an automatic (foreach)
;;     variable.  UPS is a de Bruijn index in string form: "." for the
;;     enclosing lambda, ".." for its parent, and so on.
;;
;; IFuncall: Calls an anonymous function with a vector of arguments.
;;
;; IBlock: An IBlock is a sequences of expressions, as in a `begin`
;;     expression or a function body.  All code within a block is executed,
;;     and the return values are discarded for all but the last sub-node.
;;
;; IWhere: IWhere will be expanded to the source file name, and, if POS is
;;     non-nil, a ":LINE" suffix.  When IWhere occurs within a macro, POS
;;     will be rewritten to reflect where the macro was invoked.
;;
;; ICrumb: An ICrumb holds a name/value pair that will be passed through to
;;     the `compile-text` output without affecting the behavior of the
;;     generated code.
;;
;; IEnv: Some expressions in a block context create new bindings for the
;;     environment.  In those cases, the phase 0 compilation of those
;;     expressions return an IEnv record containing the code *and* the new
;;     bindings.  These are "unwrapped" by c0-block-cc and replaced with
;;     NODE.  If phase 1 sees an IEnv record, it ignores the env field.
;;
;; Errors
;;
;;    PError records may occur where IL records may appear.  See parse.scm.


(data IL
  &public
  (IArg     &word ndx  &word ups)       ; "$(ndx)"
  (IFuncall &list nodes)                ; "$(call ^Y,NODES...)"
  (ILambda  node)                       ; (lambda-quote (c1 node))
  (IString  value)                      ; "value"
  (IVar     &word name)                 ; "$(name)"
  (IBuiltin &word name  &list nodes)    ; "$(name NODES...)"
  (ICall    &word name  &list nodes)    ; "$(call name,NODES...)"
  (IConcat  &list nodes)                ; "VALUES..."
  (IBlock   &list nodes)                ; "$(if NODES,,)"
  (IWhere   &word pos)                  ; "value"
  (ICrumb   &word key value)            ; <crumb>
  (IEnv     env &list node))            ; used during phase 0


;; Environment Records
;; -------------------
;;
;; The environment is a stack of bindings: a dictionary with newer
;; (lexically closer) bindings toward the beginning.  When used as a
;; dictionary, it maps a symbol name to its in-scope *definition*.  Each
;; definition is a vector in one of the following formats:
;;
;; NAME = the actual (global) name of the function/variable or builtin.
;;
;; SCOPE describes the scope and origin of top-level bindings:
;;
;;     "i" => defn was imported
;;     "p" => defn is private
;;     "x" => public (exported)
;;
;; ARITY = how many arguments are required by the function, in the form of a
;;    list of valid argument counts, or `N+` for "N or more".
;;
;; DEPTH = Lambda nesting depth (absolute); see current-depth.  For ELocal:
;;    the depth at which the variable is bound.  For EMacro and EIL: the
;;    depth that is the basis for resolving UPS for IArg record within IL.
;;    See c0-macro for more.
;;
;; IL = the macro definition, an IL record.
;;
;; ARGN = argument index: 1, 2, ... .
;;
;; EMarker values embed contextual data other than variable bindings.  They
;; use keys that begin with ":" to distinguish them from variable names.

(data EDefn
  &public
  (EVar     name &word scope)                  ;; simple global variable
  (EFunc    name &word scope arity)            ;; recursive global variable
  (EMacro   depth &word scope arity &list il)  ;; compound macro
  (EIL      depth &word scope &list il)        ;; symbol macro
  (EXMacro  name &word scope)                  ;; executable macro
  (ERecord  encs &word scope tag)              ;; data record type
  (EBuiltin name &word scope arity)            ;; builtin function
  (ELocal   &word argn &word depth)            ;; function argument
  (EMarker  &word data))                       ;; marker


(define `(EDefn.scope defn)
  &public
  (word 3 defn))


;; The current function nesting level: ".", "..", "...", and so on.
(define `LambdaMarkerKey
  &public
  ":")


(define `(lambda-marker depth)
  &public
  { =LambdaMarkerKey: (EMarker depth) })


;; Merge consecutive (IString ...) nodes into one node.  Retain all other
;; nodes.
;;
(define (il-merge-strings nodes accum)
  (case (first nodes)
    ((IString value)
     (il-merge-strings (rest nodes) (concat accum value)))
    (else
     (append (if accum
                 [(IString accum)])
             (word 1 nodes)
             (if (word 2 nodes)
                 (il-merge-strings (rest nodes) ""))))))


(define (il-flatten nodes)
  (append-for node nodes
              (case node
                ((IConcat children)
                 (il-flatten children))
                (else [node]))))


;; Concatenate nodes in IL domain.
;;
(define (il-concat nodes)
  &public
  (let ((nodes-out (il-merge-strings (il-flatten nodes) "")))
    (if (word 2 nodes-out)
        (IConcat nodes-out)
        (first nodes-out))))


;; Demote in IL domain
(define (il-demote node)
  &public
  (or (case node
        ((IString value) (IString (word 2 node)))
        ((ICall name args) (if (eq? name "^u")
                              (first args))))
      (ICall "^d" [node])))


;; Promote in IL domain
(define (il-promote node)
  &public
  (ICall "^u" [ node ]))


;; Construct an IL node that evaluates to a vector.  NODES is a vector of IL
;; nodes, one for each element.
;;
(define (il-vector nodes)
  &public
  (il-concat
   (intersperse (IString " ")
                (for n nodes
                     (il-demote n)))))


;; NODE is IL; A and B are actual strings.
(define (il-subst a b node)
  &public
  (case node
    ((IString value) (IString (subst a b value)))
    (else (IBuiltin "subst" [ (IString a) (IString b) node ]))))


;; Namespacing
;; -----------
;;
;; Namespaces help avoid conflicts between compiler sources and "user"
;; code, which must coexist in the same Make instance in the following
;; scenarios:
;;
;;  - In interactive mode, expressions are compiled and then executed.
;;  - An executable may be composed of modules compiled from source and
;;    other modules that had been bundled with the compiler.
;;  - Executable macros are loaded and executed during compilation.
;;
;; A "native name" for a SCAM variable is the GNU Make variable name used to
;; hold its value.  When building the compiler, we prefix the SCAM name with
;; "~".  The compile flag "--boot" indicates that we are building the
;; compiler, and *is-boot* will be true.


;; Generate a unique symbol name derived from BASE.
;;
(define (gensym-name base env suff)
  &public
  (define `name (concat base "&" suff))
  (if (filter (concat name "!=%") env)
      (gensym-name base (concat env " .") (words env))
      name))


;; Return current lambda nesting depth.
;;
;; Depth values use a unary counting system:
;;     ""   = top-level
;;     "."  = within a function
;;     ".." = within a function within a function
;;
;; The current level is indicated by a marker record in ENV.  When compiling
;; the body of a lambda, a new marker is added to increment the depth.
;;
(define (current-depth env)
  &public
  (let ((defn (dict-get LambdaMarkerKey env)))
    (case defn
      ((EMarker depth) depth))))


;; Generate a unique symbol derived from symbol BASE.  Returns new symbol.
;; The symbol is guaranteed not to conflict with any symbol in ENV, or with
;; any other symbol generated with the same ENV and a different BASE.
;;
(define (gensym base env)
  &public
  (PSymbol 0 (gensym-name (symbol-name base) env nil)))


;; Construct an error node.  The resulting error node inherits the document
;; index from FORM.
;;
(define (gen-error form fmt ...values)
  &public
  (PError (or (form-index form)
              (if (numeric? form)
                  form
                  0))
          (vsprintf fmt values)))


(define (form-description code)
  (cond
   ((eq? code "%") "form")
   ((eq? code "L") "list")
   ((eq? code "S") "symbol")
   ((eq? code "Q") "literal string")
   (else (form-typename code))))


(define (err-expected types form parent what where ?arg1 ?arg2)
  &public
  (gen-error (or form parent)
             (concat
              (if form "invalid" "missing") " " what " in " where
              (if types (concat "; expected a "
                                (concat-for ty types " or "
                                            (form-description ty)))))
             arg1 arg2))


;; ARITY = the arity of the function or macro being called (as in EMacro and
;;    EFunc entries).
;; ARGS = array of arguments
;; SYM = symbol for function/form that is being invoked
;;
(define (check-arity arity args sym)
  &public
  (define `ok
    (or (filter (concat "0+ " (words args)) arity)
        (and (findstring "+" arity)
             (word (patsubst "%+" "%" arity) args))))

  (define `expected
    (subst "+" " or more" (subst " " " or " arity)))

  (if (not ok)
      (gen-error sym
                 (subst "%S" (if (eq? expected 1) "" "s")
                        "`%s` accepts %s argument%S, not %s")
                 (symbol-name sym) expected (words args))))


(define builtins-1
  (concat "abspath basename dir error eval firstword flavor"
          " info lastword notdir origin realpath shell sort"
          " .strip suffix value warning wildcard words"))

(define builtins-2
  "addprefix addsuffix filter filter-out findstring join word")

(define builtins-3
  ".foreach patsubst .subst wordlist")

(define builtin-names
  &public
  (patsubst ".%" "%" (concat builtins-1 " "
                             builtins-2 " "
                             builtins-3 " "
                             "and or call if")))

(define base-env
  (append
   (foreach b builtins-1
            { =b: (EBuiltin (subst "." nil b) "i" 1) })
   (foreach b builtins-2
            { =b: (EBuiltin b "i" 2) })
   (foreach b builtins-3
            { =b: (EBuiltin (subst "." nil b) "i" 3)})
   (foreach b "and or call"
            { =b: (EBuiltin b "i" "0+") })
   {if: (EBuiltin "if" "i" "2 3")}

   ;; Make special variables & SCAM-defined variables
   ;; See http://www.gnu.org/software/make/manual/make.html#Special-Variables
   (foreach v ["MAKEFILE_LIST" ".DEFAULT_GOAL"]
            { =v: (EVar v "i") })))


;; Resolve a symbol to its definition, or return nil if undefined.
;; For non-symbols, return "-" (meaning, essentially, "not applicable").
;;
(define (resolve form env)
  &public
  (define `(find-name name dict)
    ;; equivalent to `(dict-find (symbol-name form) dict)` but quicker
    (filter (concat (subst "!" "!1" name) "!=%") dict))

  (case form
    ((PSymbol n name) (dict-value (or (find-name name env)
                                      (find-name name base-env))))
    (else "-")))


(define conflict-pats
  (addprefix "%" (concat builtin-names
                         " guile "
                         (foreach c "@ < ? ^ + | *"
                                  (concat c "D " c "F " c)))))


;; Return the native name to use for SCAM variable NAME.
;;
(define (gen-native-name name flags)
  &public
  (cond
   ((filter "%&native" flags) name)
   (*is-boot* (concat "`" name))
   (else (concat "'" name))))
