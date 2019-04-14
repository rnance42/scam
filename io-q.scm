(require "core.scm")
(require "string.scm")
(require "io.scm" &private)

(define SOURCEDIR
  (dir (current-file)))

(define TMPDIR
  (get-tmp-dir))

;; shell-lines

(expect [""] (shell-lines "printf ''"))
(expect ["a b c"] (shell-lines "printf 'a b c'"))
(expect ["a b c" ""] (shell-lines "printf '%b' 'a b c\\n'"))
(expect ["a b c" "" " "] (shell-lines "printf '%b' 'a b c\\n\\n '"))

;; pipe

(expect [0 "a b \n \n" ""] (pipe "printf '%b' 'a b \\n \\n'"))
(expect [0 "" "a b \n \n"] (pipe "printf '%b' 'a b \\n \\n' >&2"))
(expect [0 "a b \n" " c d"] (pipe "echo 'a b ' && echo -n ' c d' >&2"))
(expect [0 "11\n22\n" ""] (pipe "sed 's/\\(.*\\)/\\1\\1/'" "1\n2\n"))
(expect [0 "123" ""] (pipe "cat" "123"))
(expect [1 "" ""] (pipe "false"))

;; write

(expect 1 (see "Bad file descriptor" (write 543 "hi")))

;; write-file & read-file

(define `thisfile (lastword MAKEFILE_LIST))

(define `test-string
  (concat (string-from-bytecodes
           (concat "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19"
                   " 20 21 22 23 24 25 26 27 28 29 30 31 32 127"))
          "\na¢€￦\n"
          ;; <CR><LF> required special handling
          "abc\x0d\nxyz"))

(expect (concat test-string "X")
        (let ((tmpfile (concat TMPDIR "rwtest")))
          (expect nil (write-file tmpfile test-string))
          (shell (concat "echo -n X >> " tmpfile))
          (read-file tmpfile)))

(define `non-file (concat TMPDIR "io-q-dir"))
(shell (concat "mkdir -p " (quote-sh-arg non-file)))
(expect 1 (see "directory" (write-file non-file "xyz")))
;; ensure it cleaned up the temp file
(expect nil (file-exists? (concat non-file "_[tmp]")))

;; read-file

(define io-q-lines
  [ "1 tab:\tb"
    "2 a !!  c"
    ""
    "4"
    ""
    ""
    "7"
    ""])

(define io-q (concat-vec io-q-lines "\n"))

(define `test-file (concat SOURCEDIR "test/io-q.txt"))

(expect io-q (read-file test-file))
(expect io-q-lines (read-lines test-file))
(expect (wordlist 2 5 io-q-lines) (read-lines test-file 2 5))

(expect nil (read-lines (concat SOURCEDIR "does-not-exist")))

;; file-exists?

(expect (current-file) (file-exists? (current-file)))
(expect nil (file-exists? (concat SOURCEDIR "does-not-exist")))

;; cp-file

(expect 1 (see "No such" (cp-file "does-not-exist" "shall-not-exist")))
(expect nil (file-exists? "shall-not-exist"))
(expect nil (cp-file test-file (concat test-file ".2")))
(expect io-q (read-file (concat test-file ".2")))


;; hash-file & hash-files

(define TMP_XYZ (concat TMPDIR "io-q-hash"))
(write-file TMP_XYZ "xyz")
;; Exercise multiple files and space within a file name.
(define TMP_XYZ2 (concat TMPDIR " io-q! hash"))
(write-file TMP_XYZ2 "xyz2")

(expect nil *hash-cmd*)
(define xyz (hash-file TMP_XYZ))
(expect 16 (string-len xyz))

(define xyz2 (hash-file TMP_XYZ2))
(expect (hash-files [TMP_XYZ TMP_XYZ2])
        { =TMP_XYZ: xyz, =TMP_XYZ2: xyz2 })

;; hash-output

(expect "ok"
        ;; expect one (md5) or the other (sha1)
        (subst "d3b07384d113edec" "ok"   ;; md5
               "f1d2d2f924e986ac" "ok"   ;; shasum, sha1sum
               "9aa85db27d6a074c" "ok"   ;; Windows subsystem for Linux(?)
               (hash-output "echo foo")))

;; blob functions

(expect "" (read-file (save-blob TMPDIR "")))
(expect " x " (read-file (save-blob TMPDIR " x ")))
(expect "a\nx" (read-file (save-blob TMPDIR "a\nx")))
(expect "a\nb\n" (read-file (save-blob TMPDIR "a\nb\n")))

;; clean-path

(define `(cp-test a b)
  (expect (clean-path a) b))

(cp-test "." ".")
(cp-test "./" "./")
(cp-test "/." "/.")
(cp-test "/" "/")
(cp-test "a" "a")
(cp-test "a/" "a/")
(cp-test "a//b" "a/b")
(cp-test "a/.." ".")
(cp-test "a/../" "./")
(cp-test "a/../b/" "b/")
(cp-test "a/../../b/" "../b/")
(cp-test "a/.././../b/../c" "../c")
(cp-test "a/b/c/../../b/" "a/b/")
(cp-test "a/b/c/../../../b/" "b/")
(cp-test "a/b c/d/.." "a/b c")

;; resolve-path

(expect "/a" (resolve-path "dir" "/a/b/.."))
(expect "dir/a" (resolve-path "dir" "a/b/.."))

;; escape-path

(expect "foo" (escape-path "foo"))
(expect "+Tfoo" (escape-path "~foo"))
(expect "+/foo" (escape-path "/foo"))
(expect "+./foo" (escape-path "../foo"))

(define `(escape-rt str)
  (expect str (unescape-path (escape-path str)))
  (expect 1 (words (escape-path (concat "x" str "x")))))

(escape-rt "/../..a$*!#//x")
(escape-rt "+ !#\\$:;=%~*?|\t\n")

;; get-tmp-dir

(expect (or (value "SCAM_DIR") (value "SCAM_TMP"))
        (get-tmp-dir))

(let ((tmp (get-tmp-dir "io-q.XXX")))
  (assert (filter-out "/%" tmp))
  (expect 0 (first (pipe (concat "ls " (quote-sh-file tmp)))))
  (shell (concat "rm -rf " (quote-sh-file tmp))))
