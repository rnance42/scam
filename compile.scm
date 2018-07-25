;;----------------------------------------------------------------
;; compile.scm
;;----------------------------------------------------------------

(require "core.scm")
(require "parse.scm")
(require "gen.scm")
(require "gen0.scm")
(require "gen1.scm")
(require "io.scm")
(require "memo.scm")

;; The following diagram summarizes the stages of compiling a SCAM
;; expression:
;;
;;               pos                 env
;;                |                   |
;;                v                   v
;;   text    +---------+   form   +------+    IL    +------+   exe
;;  -------->|  parse  |--------->|  c0  |--------->|  c1  |-------->
;;           +---------+          +------+          +------+
;;                |                   |                 |    errors
;;                v                   v                 +----------->
;;               pos                 env
;;
;; Each expression begins at a position "pos" (a numeric index into the
;; sequence of tokens in the subject text).  Parsing emits a "form" (an AST
;; node) and a position at which to look for subsequent expressions.
;;
;; The compiler front end (c0) operates on a form and an environment (a set
;; of symbol bindings), and emits an IL node and a new environment, since
;; expressions (e.g. `declare` and `define`) can alter the environment for
;; subsequent expressions.
;;
;; The compiler back end (c1) emits executable code (Make source) and a
;; (hopefully empty) vector of errors.  The form and IL data structures can
;; convey errors as well as successful results; c1 must output a separate
;; value for error information.


(begin
  ;; Load macros. We don't directly call these modules, but they register
  ;; functions called from gen0.
  (require "macros.scm"))

(and nil
     ;; We don't use this module, but we want it bundled with the compiler.
     (require "utf8.scm"))


;; Root directory for intermediate files.
(define *obj-dir* &public ".scam/")

;; When non-nil, emit progress messages.
(define *is-quiet* &public nil)

;; Files currently being compiled (to check for cycles)
(define *compiling* nil)


;; Display a progress message.
;;
(define (build-message action file)
  (or *is-quiet*
      (write 2 (concat "... " action " " file "\n"))))


(define `(drop-if cond ?fail ?succ)
  (if cond
      (begin fail (memo-drop) 1)
      (begin succ nil)))


(define (bail-if message)
  (drop-if message (fprintf 2 "scam: %s\n" message)))


;; Return the name of the DB file for caching compilation results.
;;
(define (compile-cache-file)
  (concat *obj-dir*
          (hash-file (word 1 (value "MAKEFILE_LIST")))
          ".cache"))


(define (compile-eval text)
  (eval text))


;; Return transitive closure of a one-to-many relationship.
;; Ordering is per first ocurrence in a breadth-first search.
;;
(define (descendants fn children ?out)
  (define `new-children
    (vec-subtract (fn (first children))
                  (concat children " " out)))

  (if children
      (descendants fn (append (rest children) new-children)
                   (append out (word 1 children)))
      out))


;;----------------------------------------------------------------
;; Environment Imports/Exports
;;----------------------------------------------------------------

;; Each generated .min file includes a comment line that describes the
;; module's "final" environment state -- the lexical environment as it was
;; at the end of processing the source file.  The comment has the following
;; format:
;;
;;     "# Exports: " (env-compress <vector>)
;;
;; Both public *and* private symbols are exported.  Imported symbols are not
;; re-exported.
;;
;; Exports are consumed when `(require MOD)` is compiled.  At that time, the
;; bindings *exported* from MOD (public in its final env) are added to the
;; current environment, and marked as imported (SCOPE = "i").
;;
;; When `(require MOD &private)` is compiled, both public and private
;; symbols from MOD are added to the current environment.
;;
;; Lambda markers and local variables are not exported -- it is actually
;; impossible for them to exist in the final environment because the end of
;; the file is necessarily outside of any lambda context.


;; env-cmp and env-exp were generated by envcomp.scm.

(define (env-cmp s)
  (subst ";" "!A" "\\" "!B" "," "!C" "`" "!D" "'" "!E" "<" "!F" ">" "!G"
         "[" "!H" "]" "!I" "|" "!J" "@" "!K" "{" "!L" "}" "!M" "#" "!N"
         "\"" "!O" "&" "!P" "(" "!Q" ")" "!R" "+" "!S" "_" "!T" "!0" ";" "!1"
         "\\" "\\1" "," ";," "`" ":IL0" "'" ":IL2" "<" ":IL3" ">" ":IL4"
         "[" "\\0" "]" ",0" "|" ",11" "@" "111" "{" ",10" "}" "!=\\:EDefn"
         "#" "#1;~%;" "\"" "#1;:;" "&" " ml.special-" "(" "\"p;" ")" ")1 "
         "+" "\"i;" "_" s))

(define (env-exp s)
  (subst "_" "\"i;" "+" ")1 " ")" "\"p;" "(" " ml.special-" "&" "#1;:;" "\""
         "#1;~%;" "#" "!=\\:EDefn" "}" ",10" "{" "111" "@" ",11" "|" ",0" "]"
         "\\0" "[" ":IL4" ">" ":IL3" "<" ":IL2" "'" ":IL0" "`" ";," ","
         "\\1" "\\" "!1" ";" "!0" "!T" "_" "!S" "+" "!R" ")" "!Q" "(" "!P" "&"
         "!O" "\"" "!N" "#" "!M" "}" "!L" "{" "!K" "@" "!J" "|" "!I" "]"
         "!H" "[" "!G" ">" "!F" "<" "!E" "'" "!D" "`" "!C" "," "!B" "\\"
         "!A" ";" s))


;; Tokenize the key within the binding (it usually occurs once).
;;
(define (tokenize-key v)
  (foreach w v
           (concat
            (word 1 (subst "!=" "!= " w))
            (subst "%" "!p" (word 1 (subst "!=" " " w)) "%"
                   (word 2 (subst "!=" "!= " w))))))

(define (detokenize-key v)
  (foreach w v
           (concat
            (word 1 (subst "!=" "!= " w))
            (subst "%" (word 1 (subst "!=" " " w)) "!p" "%"
                   (word 2 (subst "!=" "!= " w))))))


;; Prepare environment V for inclusion in a line of text in the MIN file.
;;
(define (env-compress v)
  ;; Strip redundant spaces from record values; not reversible but
  ;; that's okay.
  (define `(strip-space v)
    (patsubst "%!0" "%" v))

  (env-cmp
   (tokenize-key
    (strip-space
     (subst "\n" "!n" v)))))


;; Recover an environment value produced by env-compress.
;;
(define `(env-expand str)
   (subst "!n" "\n"




          (detokenize-key
           (env-exp str))))


;; Return all bindings exported from a MIN file.  The keys of non-public
;; entries are prefixed with "(".
;;
(define `(env-parse lines all)
  (subst "!n" "\n"
         (env-expand
          (foreach prefix (append "Exports" (if all "Private"))
                   (promote (filtersub (concat ["# "] prefix [": %"])
                                       "%" lines))))))


(define (export-defn name rec)
  (define `(EDefn.set-scope rec scope)
    (append (wordlist 1 2 rec) scope (nth-rest 4 rec)))

  (concat (EDefn.scope rec) ":"
          {=name: (EDefn.set-scope rec "i")}))


;; Generate two comment lines that describe public and private bindings.
;;
(define (env-export-lines env)
  ;; Prefix each entry with its scope (e.g. "x:..." or "p:...")
  ;; and replace the scope with "i".
  (define `(prefix-entries e)
    (filter "p:% x:%"
            (foreach b (dict-compact e)
                     (export-defn (dict-key b) (dict-value b)))))

  (let ((e (prefix-entries env)))
    (concat "# Exports: " (env-compress (filtersub "x:%" "%" e)) "\n"
            "# Private: " (env-compress (filtersub "p:%" "%" e)) "\n")))


;;--------------------------------------------------------------
;; Module management
;;--------------------------------------------------------------

;; We have different ways of referring to modules in different contexts:
;;
;; NAME: This is the literal string argument to `require`.
;;
;; ORIGIN: If NAME identifies a source file, it will be the path to the
;;    source file, ending in ".scm".  If NAME identifies a builtin
;;    module, it will be that module's ID (which begins with `'`).
;;
;; ID: This is passed to ^require at run-time.  The bundle variable name
;;    and the compiled module name are based on this string, which is
;;    escaped using `escape-path`.  Modules that are bundled with the
;;    compiler are named differently to avoid conflicts with user
;;    modules [both user modules and builtin modules can be bundled in a
;;    user program].
;;
;;                  (normal)         (normal)        *is-boot*
;;                  Source File      Builtin         Source File
;;                  ------------     ------------    ------------
;;   NAME           io.scm           io              io.scm
;;   ORIGIN         io.scm           io              io.scm
;;   ID             io.scm           io              io
;;   Load File      .scam/io.scm.o                   .scam/io.o
;;   Load Bundle                     [mod-io]
;;   Bundle as      [mod-io.scm]     [mod-io]        [mod-io]
;;


;; Return the file that holds (or will hold) the module's compiled code
;; (valid only for modules compiled from source).
;;
(define (modid-file id)
  (concat *obj-dir* id ".o"))


;; Return the bundle variable that holds (or will hold) the modules's code.
;;
(define `(modid-var id)
  (concat "[mod-" id "]"))


;; Return the first 4 lines of a compiled module as an array of lines.
;;
(define (modid-read-lines id ?max)
  (if (or (filter "%.scm" id) *is-boot*)
      ;; load file
      (begin
        (memo-hash-file (modid-file id))
        (read-lines (modid-file id) (and max 1) max))
      ;; load bundle
      (wordlist 1 (or max 99999999) (split "\n" (value (modid-var id))))))


;; Scan a builtin module for `require` dependencies.
;;
(define (modid-deps id)
  (let ((lines (modid-read-lines id 4)))
    ;; should not happen... module was not compiled?
    (assert lines)
    (promote (filtersub [(concat "# Requires: %")] "%" lines))))


;; Return the environment exported from a module, given its ID.
;;
(define (modid-import id all)
  (env-parse (modid-read-lines id 4) all))


;; Construct the ID corresponding to a module origin.
;;
(define (module-id orgn)
  (let ((e (escape-path orgn)))
    (if *is-boot*
        (basename e)
        e)))


;; Get the "origin" of the module.  This is either the path of a SCAM
;; source file (ending in .scm) or a builtin module ("core", etc.).
;; Return nil on failure.
;;
;; SOURCE-DIR = directory containing the source file calling `require`
;; NAME = the literal string passed to "require"
;;
(define (locate-module source-dir name)
  (define `path-dirs
    (addsuffix "/" (split ":" (value "SCAM_LIBPATH"))))

  (or (and (filter "%.scm" [name])
           (vec-or
            (for dir (cons source-dir path-dirs)
                 (wildcard (resolve-path dir name)))))
      (and (not *is-boot*)
           (if (bound? (modid-var name))
               name))))


;; do-locate-module is safe to memoize because:
;;  1. results will not change during a program invocation.
;;  2. it does not call memo-io or memo-call
;;
(memoize (native-name locate-module))

(define (m-locate-module source-dir name)
  (memo-io (native-name locate-module) source-dir name))


;; Skip initial comment lines, retaining comment lines that match
;; the pattern RETAIN-PAT.
;;
(define (skip-comments lines retain-pat)
  (if (filter ["#%" ""] (word 1 lines))
      (append (filter retain-pat (word 1 lines))
              (skip-comments (rest lines) retain-pat))
      lines))


;; Construct a bundle for a compiled module.
;;
(define (construct-bundle id keep-syms)
  (define `body
    (skip-comments (modid-read-lines id)
                   (if keep-syms
                       ["# Req%" "# Exp%"])))

  (concat "\ndefine " (modid-var id) "\n"
          (concat-vec body "\n") "\n"
          "endef\n"))


;; This preamble makes the resulting file both a valid shell script and a
;; valid makefile.  When invoked by the shell, the script invokes `make` to
;; process the script as a makefile.
;;
;; LC_ALL=C allows makefiles to contain non-UTF-8 byte sequences, which is
;; needed to enable SCAM's UTF-8 support.
;;
;; Some make distros (Ubuntu) ignore the environment's SHELL and set it to
;; /bin/sh.  We set it to bash rather than bothering to test `io` with
;; others.
;;
(define `prologue
"#!/bin/bash
:; for v in \"${@//!/!1}\" ; do v=${v// /!0} ; v=${v//	/!+}; a[++n]=${v:-!.} ; done ; LC_ALL=C SCAM_ARGS=${a[*]} exec make -Rr --no-print-directory -f\"$0\" 9>&1
SHELL:=/bin/bash
")

(define `(epilogue main-id main-func)
  (concat "$(eval $(value " (modid-var "runtime") "))\n"
          "$(call ^start," main-id "," main-func ",$(value SCAM_ARGS))\n"))


;; Extend the runtime's ^require to handle file-based modules during
;; compilation.
;;
(define (load-ext id)
  (begin
    (eval (concat "include " (modid-file id)))
    1))


;;----------------------------------------------------------------
;; Module compilation
;;----------------------------------------------------------------

(declare (compile-module src-file))
(declare (compile-module-and-test src-file is-test))

(define `(m-compile-module infile)
  (memo-call (native-name compile-module) infile))

(define `(m-compile-module-and-test src-file untested)
  (memo-on (compile-cache-file)
           (memo-call (native-name compile-module-and-test) src-file untested)))



;; Return 1 if ENV contains an EXMacro record, nil otherwise.
;;
(define `(has-xmacro? env)
  (word 1 (foreach pair env
                   (case (dict-value pair)
                     ((EXMacro _ _) 1)))))


;; Locate or create the compiled form of a module.
;;
;;   NAME = file name or module name
;;   BASE = directory/file to which NAME may be relative
;;   PRIVATE = include private as well as public bindings
;;
;; Returns: a CMod record
;;
(define (get-module name base private)
  &public
  (let ((orgn (m-locate-module (dir base) name))
        (private private))
    (define `id (module-id orgn))

    (or (if (not orgn)
            (ModError (sprintf "cannot find %q" name)))
        (if (filter "%.scm" [orgn])
            (if (m-compile-module-and-test orgn private)
                (ModError (sprintf "compilation of %q failed" orgn))
                ;; success => nil => proceed to ordinary result
                nil))
        (let ((exports (memo-blob-call (native-name modid-import) id private))
              (id id) (orgn orgn))
          (or (if (has-xmacro? exports)
                  (if *is-boot*
                      ;; do not require at run-time, and
                      (ModError "module has executable macros (boot=true)")
                      ;; require module and continue
                      (call "^require" id)))
              (ModSuccess id exports))))))


;;----------------------------------------------------------------

;; Get the name of the runtime module.
;;
(define (runtime-module-name source)
  (if *is-boot*
      ;; When booting, build runtime from source, and avoid a circular
      ;; dependency.  Avoid treating "runtime.scm" as an implicit
      ;; dependency of runtime-q.scm to avoid a circular dependency on
      ;; testing.
      (filter-out (subst "-q.scm" ".scm" [source]) "runtime.scm")
      ;; Normal compilation: use builtin
      "runtime"))


;; Return an initial environment (standard prelude).
;;
;; We construct this environment by effectively calling `require` on
;; "implicit" modules (user programs do not know they exist).  Normally this
;; pulls in symbols from a builtin module, but during compiler "boot" phase
;; this will ensure compilation of these modules from source.
;;
(define (compile-prelude source)
  &public

  (define `(get-module-env name)
    (let ((o (get-module name "." nil)))
      (case o
        ((ModSuccess id exports)
         exports)
        ((ModError desc)
         (error desc)))))

  (foreach m (runtime-module-name source)
           (get-module-env m)))


;; Compile SCAM source to executable code.
;;
;; Returns:
;;    { code: CODE, errors: ERRORS, env: ENV-OUT, requires: MODS }
;;
;; TEXT = SCAM source
;; ENV = Initial environment. This is normally generated by compile-prelude.
;;       It includes exports from implicit modules, unless the file being
;;       compiled is itself an implicit module.  When called from the REPL,
;;       this will contain additional bindings from the user's session.
;; INFILE = Input file name (or '[command line]').
;; IS-FILE = When nil, code will be compiled for function syntax.  When
;;           non-nil, code will be compiled for file syntax.
;;
(define (compile-text text env infile is-file)
  &public
  (let-global ((*compile-subject*  (penc text))
               (*compile-file*     infile))

    (c0-block-cc env
                 (parse-subject *compile-subject*)
                 (lambda (env-out nodes)
                   (concat (gen1 nodes is-file) " " {env: env-out})))))


;; Replace the first line with a blank line if it begins with "#".
;;
(define (trim-hashbang text)
  (if (filter "#%" (word 1 text))
      (concat "\n" (concat-vec (rest (split "\n" text)) "\n"))
      text))


(define `(check-cycle file)
  (if (vec-intersect *compiling* [file])
      (bail-if (concat "dependency loop: "
                       (concat-vec (conj *compiling* file) " -> ")))))


;; Compile a SCAM source file and all ites dependencies.
;; On success, return nil.
;; On failure, display message and return 1.
;;
;; INFILE = source file name (to be read)
;;
(define (compile-module infile)
  (define `text (trim-hashbang (memo-read-file infile)))
  (define `outfile (modid-file (module-id infile)))
  (define `imports (compile-prelude infile))

  (or
   (check-cycle infile)
   (let-global ((*compiling* (conj *compiling* infile)))

     (build-message "compiling" infile)

     (let ((o (compile-text text imports infile outfile))
           (infile infile)
           (outfile outfile))
       (define `errors (dict-get "errors" o))
       (define `exe (dict-get "code" o))
       (define `env-out (dict-get "env" o))
       (define `reqs (dict-get "require" o))

       (drop-if
        errors
        ;; Error case
        (for e errors
             (info (describe-error e text infile)))

        ;; Success
        (begin
          (define `content
            (concat "# Requires: " reqs "\n"
                    (env-export-lines env-out)
                    exe))

          (memo-call (native-name memo-mkdir-p) (dir outfile))
          (bail-if (memo-write-file outfile content))))))))


;; Construct a bundled executable from a compiled module.
;;
;; EXE-FILE = exectuable file to create
;; MAIN-ID = module ID for the main module (previously compiled, so that
;;     object files for it and its dependencies are available).
;;
(define (link exe-file main-id)
  (build-message "linking" exe-file)

  (define `main-func (gen-native-name "main" nil))
  (define `roots (uniq (append main-id
                               (foreach m (runtime-module-name nil)
                                        (module-id m)))))

  (define `bundles
    (let ((mod-ids (descendants modid-deps roots)))
      ;; Symbols are valuable only if 'compile is present
      (define `keep-syms (filter "compile" mod-ids))
      (concat-for id mod-ids ""
                  (construct-bundle id keep-syms))))

  (define `exe-code
    (concat prologue bundles (epilogue main-id main-func)))

  (or (bail-if (memo-write-file exe-file exe-code))
      (bail-if (shell (concat "chmod +x " (quote-sh-arg exe-file))))))


(define (m-link exe-file main-id)
  (memo-call (native-name link) exe-file main-id))


;; Link and run a test module.
;; On success, return nil.
;; On failure, return 1.
;;
(define (run-test exe mod)
  ;; ensure it begins with "./" or "/"
  (or (m-link exe mod)
      (begin
        (build-message "running" exe)

        ;; track dependency for memoization
        (memo-hash-file exe)

        (define `cmd-name (concat (dir exe) (notdir exe)))
        (define `cmd-line
          (concat "TEST_DIR=" (quote-sh-arg *obj-dir*) " "
                  (quote-sh-arg cmd-name) " >&2 ;"
                  "echo \" $?\""))

        (drop-if (filter-out 0 (lastword (logshell cmd-line)))))))


;; Compile a module and test it.
;; On success, return nil.
;; On failure, display message and return 1.
;;
(define (compile-module-and-test src-file untested)
  (define `test-src (subst ".scm" "-q.scm" src-file))
  (define `test-mod (module-id test-src))
  (define `test-exe (basename (modid-file test-mod)))

  (or (m-compile-module src-file)
      (and (not untested)
           (file-exists? test-src)
           (or (m-compile-module test-src)
               (if (memo-call (native-name run-test) test-exe test-mod)
                   (bail-if (concat test-src " failed")))))))


;; Compile a SCAM program.
;; On success, return nil.
;; On failure, display message and return 1.
;;
;; EXE-FILE = exectuable file to create
;; SRC-FILE = source file of the main module
;; OPTS = command-line options
;;
(define (compile-program exe-file src-file)
  &public
  (define `main-id (module-id src-file))

  (if (file-exists? src-file)
      (memo-on (compile-cache-file)
               (or (m-compile-module-and-test src-file nil)
                   (m-link exe-file main-id)))
      ;; file does not exist
      (begin
        (fprintf 2 "scam: file '%s' does not exist\n" src-file)
        1)))


;; Compile a program and then execute it.
;; On success, return nil.
;; On failure, display message and return 1.
;;
(define (compile-and-run src-file argv)
  &public

  (define `exe-file
    (basename (modid-file (module-id src-file))))

  ;; Option 1: link and run via rule

  (define `run-cmd
    (concat "SCAM_ARGS=" (quote-sh-arg argv)
            " make -f " (quote-sh-arg exe-file)))

  (or (compile-program exe-file src-file)
      (compile-eval (concat ".PHONY: [run]\n"
                            "[run]: ; @" (subst "$" "$$" run-cmd)))))
