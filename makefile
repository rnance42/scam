# bin/scam holds the "golden" compiler executable, which bootstraps compiler
# generation.  From the source files we build to three different sets of
# exectuable code:
#
#    Compiler  Output  Runtime used by the code
#    --------  ------  -----------------------------
#    golden     $A     golden (bundled in bin/scam)
#    $A         $B     current ($B/runtime.min)
#    $B         $C     current (bundled in $B/scam)
#
# Generated code will implicitly depend on a runtime, because the compiler's
# code generation phase emits references to runtime functions.  When we
# modify the compiler sources we can change the runtime code as long as we
# change the corresponding code generation code.  However, to support this
# we need to avoid mismatches at run time.  Code generated by the golden
# compiler must use the golden runtime, and code generates by a current
# compiler (e.g. a/scam) must use a runtime compiled from current sources.
# The combinations are summarized above, and these imply some complications
# that should be called out:
#
#  1. $A/scam contains and uses the golden runtime.  However, code that IT
#     GENERATES must use a current runtime.  This means that the `scam -x
#     ...` cannot be supported by the a compiler, so we do not run those
#     tests against the a compiler.
#
#  2. In order to support `scam -o ...`, the a compiler must bundle a
#     current runtime into the generated program ... NOT the one bundled
#     within itself.  We name `runtime.scm` on the command line as a source
#     file, which tells the program to build, test, and bundle THAT runtime,
#     not its own bundled one.
#
#  3. runtime.scm presents its own potential conflict: it cannot use any
#     other runtime because of symbol conflicts, and so building the current
#     runtime sources with a golden compiler would be problematic.  As a
#     result, we do not build and run $A/runtime.min or $A/runtime-q.min.
#     Instead, we generate `b` binaries for these using the `a` compiler.

_@ = @
A = .out/a
B = .out/b
C = .out/c

arg = $(subst ','\'',$1)# ' balanced for emacs
qarg = '$(arg)'
target-line = $(shell sed -n '/^$@:/=' makefile)

# guard: drop stdout and print message on failure
guard = ( $1 ) > /dev/null || (echo 'makefile:$(target-line): $@ failed:' && /bin/echo " $$ "$(qarg) && false)

.PHONY: a b c aok bok cok promote install clean

cok:

$A/scam: *.scm bin/scam ; $(_@) bin/scam -o $@ scam.scm
$B/scam: *.scm $A/scam  ; $(_@) $A/scam -o $@ --symbols scam.scm --boot
$C/scam: *.scm $B/scam  ; $(_@) $B/scam -o $@ --symbols scam.scm --boot


a: $A/scam
b: aok $B/scam
c: bok $C/scam


# v1 tests:
#  run: validates code generation
#
aok: $A/scam
	$(_@) SCAM_LIBPATH='.' $A/scam -o .out/ta/run test/run.scm --boot
	$(_@) .out/ta/run

# v2 tests:
#   dash-o: test program generated with "scam -o EXE"
#     Uses a bundled file, so $A/scam will not always work.
#   dash-x: compile and execute source file, passing arguments

bok-o: b
	$(_@) $B/scam -o .out/tb/using test/using.scm
	$(_@) .out/tb/using
	$(_@) $B/scam -o .out/tb/dash-o test/dash-o.scm
	$(_@) $(call guard,grep 'require.test/subdir/dup' .out/tb/.scam/test/dash-o.min)
	$(_@) .out/tb/dash-o 1 2 > .out/tb/dash-o.out
	$(_@) $(call guard,grep 'result=11:2' .out/tb/dash-o.out)

bok-x: b
	$(_@) SCAM_TRACE='%conc:c' $B/scam --out-dir .out/tbx/ -x test/dash-x.scm 3 'a b' > .out/tb/dash-x.out
	$(_@) $(call guard,grep '9:3:a b' .out/tb/dash-x.out)
	$(_@) $(call guard,grep ' 4 : .*conc' .out/tb/dash-x.out)

bok-i: b
	$(_@) $(call guard,$B/scam <<< $$'(^ 3 7)\n:q\n' 2>&1 | grep 2187)

bok: bok-o bok-x bok-i

# To verify the compiler, we ensure that $B/scam and $C/scam are identical.
# $A/scam differs from bin/scam because it is built from newer source files.
# $A and $B differ because they are built by different compilers, but they
# should *behave* the same because they share the same sources ... so $B and
# $C should be identical, unless there is a bug.  We exclude exports from
# the comparison because they mention file paths, which always differ.
#
cok: c
	@echo cok...
	$(_@)grep -v Exports $B/scam > $B/scam.e
	$(_@)grep -v Exports $C/scam > $C/scam.e
	$(_@)diff -q $B/scam.e $C/scam.e

# Replace the "golden" compiler with a newer one.
#
promote: cok
	$(_@)cp $B/scam bin/scam

install:
	cp bin/scam `which scam`

clean:
	rm -rf .out .scam

bench:
	bin/scam --out-dir .out/ -x bench.scm


$$%:
	@true $(info $$$* --> "$(call if,,,$$$*)")
