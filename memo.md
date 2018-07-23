# memo.scm

The `memo` module supports memoization.  The source file contains API
documentation.  This document describes the theory of operation, and
introduces some terminology, concepts, and implications that programmers
should be aware of when using memo.scm.


### Wrapping a function call or expression.

In order to utilize memoization, the programmer must identify what
procedures are to be memoized and replace an existing expression or function
call with a caching wrapper.  For example, we can replace:

    (foo a b c)

... with:

    (memo-apply (global-name foo) [a b c])

We say that a function call is "memoized" when it is replaced with a
caching wrapper (e.g. memo-apply or memo-call).

Memoization of a function call is *valid* when the memoized form is
*equivalent* to the original form.  By "equivalent" we mean that the
behavior of the program will not be affected by the transformation
(except for time of execution, and except for strictly
memoization-related activity such as reading and writing cache files).

For any SCAM function is "pure functions" -- that is, its result value is
uniquely determined by their inputs, and it has no side effects -- supplying
a cached value from previous invocation (with the same inputs) will be
indistinguishable from invoking the procedure again.  Use of memoization
with pure functions is therefore valid.


### IO

Memo supports memoization of procedures that perform IO as long as the IO
operations meet the following constraints:

 - Operations that mutate external state must have an idempotent effect.
   (Performing the operation once must be equivalent to performing it two
   or more times.)  [Note that this rules out read operations that depend
   on and modify an external cursor or "seek position".]

 - The memo module must be apprised of each IO operation performed.

This may be accomplished by using the IO functions exposed by the memo
module -- memo-read-file, memo-write-file, etc. -- or by constructing custom
IO functions and calling them through `memo-io`.

IO operations have two different impacts on memoization.  First, the return
value of each IO operation is effectively an additional "input" value to the
memoized procedure, since it can affect the subsequent behavior of the
procedure.  The memoization cannot use a cached value (and *skip* calling
the actual function) until is validates that the previously-called IO
operations will return the same values (if they were to be called).

Second, an IO operation can have side effects.  In order to ensure that
memoization is valid -- i.e., that a memoized call is equivalent to actual
invocation of the function -- the memoized call will skip invocation only
when it can validate that side effects are equivalent (or make it so).


#### Nested Calls

Memoized procedures can call other memoized procedures.  Values returned by
a nested call are treated as dependencies of the parent, similarly to how IO
operations are handled.  Otherwise, each memoized operation is cached
independently.

For example, consider two memoized functions: f and g, and a previously
cached call in which f called g, and in which both f and g perform IO.  It
is possible for g to experience a cache miss (requiring re-invoking the
original procedure) without f experiencing a cache miss.  For example, one
of g's IO operations might now return a different value than previously,
causing g to be re-invoked, but as long as the return value of g remains the
same it will not invalidate the cached result for f.  Likewise, changes to
f's inputs or f's IO results could cause a cache miss for f while g's cache
entries remain relevant and usable.


### Sessions

A session is a span of time during which we place constraints on changes
to external state: During a session, any IO operation when called with
the same arguments will return the same value.

For example: Files being read by the program must not be modified by
external entities during a session, and no file may be modified by the
program itself *after* it has been read.

The `memo-on` call is used to indicate the duration of sessions.

These assumptions are important for enabling certain implementation
approaches and for constructing an argument for validity of memoization.

For example, during a compiler invocation we assume that source files are
not being modified by external entities.  This assumption is reasonable
because it would be extremely difficult to define compilation results in
such a scenario.  For memoization, this assumption allows more efficient
caching.  We can treat a compiler "invocation" as a session, and then the
memo module can safely use cached results from earlier in the session
without re-validating input operations.


### Ephemeral vs. Persistent Memoization

During a session, the results of memoized functions are stored in a cache.
When a subsequent call is made within the same session to the same function
with the same arguments, the cached result will be supplied.  The memoize
function will not be called, and its IO operations (if any) will not be
re-validated.  We call this "ephemeral" caching.

When there is no matching call within the same session, calls from a
previous session are examined.  If there is a match, then the IO operations
performed by the previous call are replayed, and if their return values
match a previous call, the result from the previous call is supplied and the
memoized function is not called.  We call this "persistent" caching.

When a persistent cache entry is used during a session, its result is added
to the ephemeral cache, so that subsequent matching calls in the same
session will return immediately without re-validation of IO.

    For an example of the implications of ephemeral and persistent
    memoization, consider the example of SCAM compilation.  Persistent
    memoization enables incremental builds: the second time the compiler
    is invoked to compile a given source file, build results from the
    prior invocation will be re-used if their dependencies have not
    changed.  The IO re-validation step detects when source files in this
    session (compiler invocation) are the same as in a previous session.
    Ephemeral memoization, on the other hand, provides an important
    optimization within each session.  Since a SCAM module may depend on
    exports from a required module, each `require` statement triggers
    compilation of the required file, which in turn can trigger
    compilation of other files.  There can be no dependency cycles, but
    the number of compilations can grow exponentially.  Without ephemeral
    caching, we would have the benefit of persistent caching, but each
    persistent cache hit involves re-validation of the call's IO and
    nested memoized calls.  While each file would be *compiled* only
    once, the re-validation of IO would grow exponentially.  Ephemeral
    caching is the avoidance of IO re-validation during a session.


### Dropping Memoization

A memoized function may choose to "drop" memoization for the current call.
This will prevent persistent caching of the current invocation, discarding
the cache data relevant to it.  This can be used in error scenarios in order
to avoid cluttering the database with entries that are unlikely to be
valuable.