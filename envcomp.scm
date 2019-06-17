;;--------------------------------
;; envcomp.scm
;;--------------------------------

;; Analyze compression performance.

(require "core")
(require "gen")
(require "io")
(require "math.scm")
(require "string")
(require "compile.scm" &private)


;; Single character values that can be used to replace longer strings.
;; Ideally, these should occur rarely or never in the environment.
;;
(define `subchars
  "; \\ , ' [ ] | @ { } # \" & ( ) _ / $ < > + `")

(expect subchars
        (uniq subchars))

;; Escape codes that will replace subchars.
;;
(define `escape-codes
  (addprefix
   "!"
   "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"))


;; Count number of occurrences of SUBSTR in STR.
;;
(define (count substr str)
  (words (rest (split substr str))))


;; Count occurrences of each string in SUBS, and calculate potential
;; savings (if replaced with a single byte).  Returns a sorted
;; vector of [SAVINGS COUNTS STR].
;;
(define (freqs subs env)
  (reverse
   (sort-by
    (lambda (e) (num-lex (strip (first e))))
    (for c subs
         (let ((n (count c env)))
           [ (format-fixed
              (-
               ;; bytes saved by replacement
               (* n (- (string-len c) 1))
               ;; cost
               (* 2 (string-len c)))
              5)
             (format-fixed n 4)                      ; # occurrences
             c ])))))                                ; substring


;; Display occurrences and savings for each string in SUBS.  MAP maps the
;; string to some other value (e.g its value before prior substitutions).
;;
(define (rank-freqs subs env ?map)
  (for e (freqs subs env)
       (printf "%s %s \"%s\""
               (nth 1 e)
               (nth 2 e)
               (dict-get (nth 3 e) map (nth 3 e)))))


;; Compress target by replacing each string in SUBS with a string in CHARS.
;; don't care which byte is used to encode the substring).  It is assumed
;; that none of TO-STRINGS appear anywhere in FROM-STRINGS.
;;
(define (reduce-string target from-strings to-strings)
  (define `s1 (first from-strings))
  (define `(reduce x) (subst s1 (first to-strings) x))

  (if from-strings
      (reduce-string (reduce target)
                     (for s (rest from-strings) (reduce s))
                     (rest to-strings))
      target))

(expect (reduce-string "abcdefg" ["abc" "abcd" "abcdef"] [0 1 2])
        "2g")


;; Substitute FROM-STRINGS with TO-STRINGS in SUBS.  Each substitution
;; also applies to subsequent strings in FROM_STRINGS.
;;
(define (reduce-strings subs from-strings to-strings)
  (for s subs
       (reduce-string s from-strings to-strings)))


(define (compare-size label original new)
  (printf "%s : %s -> %s  %s%% reduction"
          label original new
          (/ (* (- original new) 100) original 4)))


(define (compile-subs subs subchars)
  (define `from (first subs))
  (define `to (first subchars))

  (if subs
      (append [from to]
              (compile-subs (for s (rest subs)
                                 (subst from to s))
                            (rest subchars)))))


(define (compile-cmp subs subchars)
  (define `(format-string str)
    (.. "\"" (subst "\\" "\\\\" "\"" "\\\"" str) "\""))
  (define `chars-used
    (wordlist 1 (words subs) subchars))

  ;; Encode subchars first, while the conditions that ensure reversibility
  ;; still hold ("!" only appears in an escape code).
  (let ((args (append
                (compile-subs chars-used escape-codes)
                (compile-subs subs subchars))))
    (printf "(define (cmp s) (subst %s s))"
            (concat-for a args " " (format-string a)))
    (printf "(define (exp s) (subst %s s))"
            (concat-for a (reverse args) " " (format-string a)))))


;; Compress TARGET with SUBS and then show relative value of each of
;; CANDIDATES.
;;
(define (rank-after target subs candidates)
  (let ((ex (reduce-string target subs subchars))
        (cx (append-for c candidates
                        {(reduce-string c subs subchars): c}))
        (size0 (string-len target)))
    (rank-freqs (dict-keys cx) ex cx)
    (compare-size "size" size0 (string-len ex))
    (compile-cmp subs subchars)
    ex))


;;--------------------------------
;; main
;;--------------------------------

;;
;; Load exports from .out/b/scam
;;

(define scam-env
  (let ((export-lines (shell-lines "grep '# Exports' .out/b/scam")))
    (print ".out/b/scam exports:")
    ;; (printf "exports: %s bytes" (string-len (concat-vec export-lines "\n")))
    (printf "compressed: %s bytes"
            (string-len
             (concat-vec (patsubst ["# Exports: %"] "%"
                                   export-lines) "\n")))
    (strip
     (foreach line export-lines
              (env-parse line nil)))))

(define scam-tenv (tokenize-key scam-env))

(printf "raw:        %s bytes [%s entries]" (string-len scam-env) (words scam-env))
(printf "tokenized:  %s bytes" (string-len scam-tenv))

;; Uncomment for manual inspection:
(write-file ".out/tenv" scam-tenv)


(define `candidate-strings
  [
    "!11111"
    "!1111"
    "!111"
    "!0"
    "!1"
    "!10"
    "!101"        ;; argc?
    "!11"
    "!110"
    "!111"
    "!1110"
    "!1111"
    "!11111"
    "!11110"
    "!0!11"
    "!=!1:EDefn"
    "!=!1:EDefn0"
    "!=!1:EDefn1"
    "!=!1:EDefn2"
    "!=!1:EDefn5"
    "0!11"
    "10"
    "110"
    "111"
    "1110"
    "1111"
    ":IL0"
    ":IL1"
    ":IL2"
    ":IL3"
    ":IL4"
    ":IL5"
    ":IL6"
    ":IL7"
    ":IL8"
    "1:IL"
    "!0!1:IL"
    "1 "
    "2 "
    "!01 "
    "!02 "
    "filter"
    "word"
    "i!0%!01"
    "i!0%!0"
    "2!0i!0.!0"
    "2!0i!0.!01"
    "2!0i!0.!02"
    "!=!1:EDefn1!0i"
    "!=!1:EDefn1!0i!0%!0"
    "!=!1:EDefn2!0i"
    "!=!1:EDefn2!0i!0.!0"
    "!1:EDefn2!0i!0.!01!0!1:IL"
    "!0!11:IL"
    "!10.!0!11:IL"
    "!0!11:IL0!101!10."
    ])

;; (rank-after scam-tenv [] candidate-strings)

(define `compress-strings
  [
    "!=!1:EDefn1!0i!0%!0"  ;; 3004
    "!=!1:EDefn2!0i!0.!0"  ;; 988
    "!11"                  ;; 788
    "!10"                  ;; 788
    "!0!11:IL"             ;; 778
    "!=!1:EDefn"           ;; 349
    "!0"                   ;; 375
    "1:IL"                 ;; 202
    "!0!1:IL"              ;; 112
    "!0!11:IL0!101!10."    ;; 168
    ;; "1 "                   ;; 87
   ])


(define (subtract v1 v2)
  (define `(e s) (subst "~" "~1" "%" "~p" s))
  (define `(d s) (subst "~p" "%" "~1" "~" s))
  (d (filter-out (e v2) (e v1))))

;;
;; Estimate savings of compress-strings.
;; Output source for the resulting compress and expand functions.
;; Display benefits of additional candidate strings.
;;
;; (print "in: " scam-tenv)
(print "saves reps str")
(print "----- ---- ---------")
(rank-after scam-tenv compress-strings
            (subtract candidate-strings compress-strings))

;;(print "raw:\n" (reduce-string scam-tenv compress-strings subchars))


;;
;; Rank sub-chars, lest-frequent first.
;;

(define best-chars
  (sort-by (lambda (c) (format-fixed (count c scam-tenv) 6))
           subchars))

;; (printf "best-chars: (%s)  %q " (words best-chars) best-chars)
;; Display actual number of occurrences:
(foreach c best-chars (printf "'%s' x %s" c (count c scam-tenv)))



;;
;; Validate compress & expand functions generated by a recent run.
;;

(define (cmp s)
  (subst ";" "!A" "\\" "!B" "," "!C" "'" "!D" "[" "!E" "]" "!F" "|" "!G"
         "@" "!H" "{" "!I" "}" "!J" "!=!1:EDefn1!0i!0%!0" ";"
         "!=!1:EDefn2!0i!0.!0" "\\" "!11" "," "!10" "'" "!0,:IL" "["
         "!=!1:EDefn" "]" "!0" "|" "1:IL" "@" "|!@" "{" "[0'1'." "}" s))

(define (exp s)
  (subst "}" "[0'1'." "{" "|!@" "@" "1:IL" "|" "!0" "]" "!=!1:EDefn"
         "[" "!0,:IL" "'" "!10" "," "!11" "\\" "!=!1:EDefn2!0i!0.!0"
         ";" "!=!1:EDefn1!0i!0%!0" "!J" "}" "!I" "{" "!H" "@" "!G" "|" "!F"
         "]" "!E" "[" "!D" "'" "!C" "," "!B" "\\" "!A" ";" s))

(compare-size "size"
              (string-len scam-tenv)
              (string-len (concat (cmp scam-tenv) cmp exp)))

(expect (exp (cmp scam-tenv))
        scam-tenv)
