# Wisp Language Reference

This document describes the intended core surface of Wisp.

It is a language reference, not a tutorial, implementation report, or VM spec.

Wisp is a small eager Lisp with s-expression syntax, lexical scope, mutable bindings, immutable lists, mutable vectors, and first-class functions.

Wisp does not currently specify quote, eval, macros, symbol literals, or source-as-data semantics.

## Source Shape

A Wisp file is a sequence of top-level forms evaluated in order.

```scheme
(def x 10)
(print x)
(+ x 1)
```

A file may contain only definitions.

```scheme
(def x 10)
(def y 20)
```

A file may be empty. File evaluation does not require a final expression result.

Newlines are whitespace.

Line comments start with `;` and continue to the end of the line.

```scheme
; comment
(def x 10) ; comment
```

## Lexical Elements

Wisp source consists of names, literals, lists, vectors, comments, and whitespace.

Names are non-delimiter atoms that are not literals or number literals.

Examples:

```scheme
x
player-name
+
<=
foo.1
```

The literal names are:

```text
nil
true
false
```

They produce literal values and cannot be bound as ordinary names.

Special form names have fixed language meaning:

```text
def
set
do
if
while
fn
```

Special form names are reserved and cannot be bound as ordinary names.

Built-in functions are immutable global function bindings supplied by Wisp.

Built-in function names are not reserved.

User definitions may shadow global bindings, including built-in functions.

## Runtime Values

Core value kinds:

```text
nil
bool
int
float
string
list
vector
function
```

### Nil

`nil` is an ordinary value for absence or no useful result.

`nil` is distinct from `false`.

`nil` is distinct from the empty list.

### Truthiness

Only `nil` and `false` are falsey.

Every other value is truthy, including:

```text
0
""
()
[]
```

## Forms

Wisp source has two form categories:

```text
definitions
expressions
```

A definition creates a binding at file top level or in the current body.

An expression produces a value.

Definitions are valid only directly at file top level or inside bodies. A definition is not an expression.

```scheme
(def x 10)
```

Valid at file top level or in a body.

```scheme
(+ 1 (def x 10))
; error
```

Invalid because function arguments are expression positions.

```scheme
[(def x 10)]
; error
```

Invalid because vector elements are expression positions.

Use `do` when an expression position needs local definitions.

```scheme
(if alive
  (do
    (def message "alive")
    message)
  "dead")
```

## Bodies

`do`, `while`, `fn`, and named function definitions contain bodies.

A body is a sequence of body forms.

A body form is either a definition or an expression.

An empty body returns `nil`.

A non-empty body must end with an expression. The body returns that expression's value.

Definitions may appear earlier in the body.

```scheme
(do)
; nil
```

```scheme
(do
  (def x 10)
  x)
; 10
```

```scheme
(do
  (print "before")
  (def x 10)
  (+ x 1))
; 11
```

A non-empty body cannot end with a definition.

```scheme
(do
  (def x 10))
; error
```

File top level is program-like. A file may be empty, may contain only definitions, and may end with a definition.

## Names and Scope

Wisp uses lexical scope.

Each file has its own file scope.

Wisp has one global environment. Built-in functions are immutable bindings in the global environment.

Name lookup checks local body scopes first, then file scope, then the global environment.

A definition creates a mutable binding in the current scope. At file top level, this is the file scope. Inside `do` or `fn`, this is the current body scope.

A child scope can read visible bindings from parent scopes.

A child scope may define a name that shadows an outer binding.

A file-scope definition may shadow a global binding, including a built-in function.

A duplicate definition for the same name in the same scope is an error.

Bindings are ordered. A binding is visible only after its definition has been evaluated.

```scheme
(do
  x
  (def x 10)
  nil)
; error
```

```scheme
(do
  (def x 10)
  x)
; 10
```

A name lookup is an error if no visible binding exists.

## Definitions

### Value Definition

```scheme
(def name expr)
```

`def` is a definition form.

It evaluates `expr`, creates a new mutable binding named `name` in the current scope, and stores the value in that binding.

The new binding is visible after the `def` has evaluated.

```scheme
(def x 10)

x
; 10
```

A duplicate definition in the same scope is an error.

```scheme
(def x 1)
(def x 2)
; error
```

A local definition may shadow an outer binding.

```scheme
(def x 10)

(do
  (def x 20)
  x)
; 20

x
; 10
```

Because `def` is not an expression, it cannot be used as an argument, branch, vector element, initializer, or final body result.

```scheme
(def x (def y 10))
; error
```

```scheme
(if alive
  (def status "alive")
  "dead")
; error
```

### Named Function Definition

```scheme
(def (name params...)
  body-form...)
```

A named function definition is a definition form.

It defines `name` as a function in the current scope.

```scheme
(def (inc x)
  (+ x 1))

(inc 10)
; 11
```

It has the same user-visible meaning as defining the name with `fn`.

```scheme
(def inc
  (fn (x)
    (+ x 1)))
```

The function body follows normal body rules.

The function body is not evaluated when the named function is defined. It is evaluated only when the function is called.

An empty named function body returns `nil` when called.

```scheme
(def (noop))

(noop)
; nil
```

Named functions may call themselves recursively.

```scheme
(def (fact n)
  (if (= n 0)
    1
    (* n (fact (- n 1)))))

(fact 5)
; 120
```

Named function definitions follow normal definition rules. They are valid only at file top level or directly inside a body, are not expressions, and duplicate same-scope definitions are errors.

## Expressions

Expressions evaluate to values.

### Literals

Literal values evaluate to themselves.

```scheme
nil
true
false
10
1.5
"hello"
```

### Names

A name expression reads the current visible binding for that name.

```scheme
(def x 10)

x
; 10
```

Reading an undefined name is an error.

### Vector Literals

A vector literal creates a fresh mutable vector.

```scheme
[expr expr expr]
```

Elements are expressions evaluated left-to-right.

```scheme
(def x 10)

[1 x (+ 1 2)]
; [1 10 3]
```

Definitions are not valid inside vector literals.

```scheme
[(def x 10)]
; error
```

### List Forms

A non-empty source list in expression position is evaluated as a form.

```scheme
(head arg arg)
```

If the bare head is a special form name, that special form controls evaluation.

```scheme
(if alive "alive" "dead")
(fn (x) (+ x 1))
(do (def x 10) x)
```

Otherwise, Wisp resolves a bare head as an ordinary name.

If a visible binding exists, the list is a call through that binding.

An unresolved callee name is an error.

```scheme
(+ 1 2)
; 3
```

Built-in functions may be read and called through other bindings.

```scheme
(def add +)

(add 1 2)
; 3
```

Built-in function names may be shadowed.

```scheme
(def + (fn (a b) 999))

(+ 1 2)
; ordinary call through the file binding
```

An empty source list in expression position is an error.

```scheme
()
; error
```

## Calls

A call has this shape:

```scheme
(callee arg...)
```

The callee expression is evaluated first.

Arguments are evaluated left-to-right.

The resulting callee value is called with the resulting argument values.

Callable values:

```text
function
built-in function
vector
```

Calling any other value is an error.

A function call checks arity, creates a function scope, binds parameters, evaluates the function body, and returns the body result.

Vector calls index the vector.

```scheme
(def v [10 20 30])

(v 1)
; 20

([10 20 30] 2)
; 30
```

A vector call requires exactly one integer index.

An out-of-bounds vector index is an error.

## Special Forms

Special forms are built-in syntactic forms with special evaluation rules.

A special form is recognized only when its name appears as the head of an evaluated list form.

### Do

```scheme
(do
  body-form...)
```

`do` is an expression special form.

It creates a fresh lexical child scope, evaluates its body in that scope, and returns the body result.

```scheme
(do)
; nil
```

```scheme
(do
  (def x 10)
  (+ x 1))
; 11
```

Bindings created inside `do` are not directly visible outside that scope.

```scheme
(do
  (def x 10)
  x)
; 10

x
; error
```

A non-empty `do` body must end with an expression.

```scheme
(do
  (def x 10))
; error
```

### If

```scheme
(if cond then)
(if cond then else)
```

`if` is an expression special form.

It evaluates `cond` first.

If `cond` is truthy, it evaluates and returns the `then` expression.

If `cond` is falsey and an `else` expression exists, it evaluates and returns the `else` expression.

If `cond` is falsey and no `else` expression exists, it returns `nil`.

Only the selected branch is evaluated.

Branches are expression positions.

```scheme
(if true
  10
  20)
; 10

(if false
  10
  20)
; 20

(if false
  10)
; nil
```

Because branches are expressions, `def` cannot appear directly as a branch.

```scheme
(if alive
  (def status "alive")
  "dead")
; error
```

Use `do` when a branch needs local definitions or multiple forms.

```scheme
(if alive
  (do
    (def message "alive")
    (print message)
    message)
  "dead")
; prints alive
; returns "alive"
```

The branch-local binding does not escape the `do` branch.

```scheme
message
; error
```

### While

```scheme
(while cond
  body-form...)
```

`while` is an expression special form.

The condition is evaluated in the surrounding scope before each iteration.

If the condition result is falsey, `while` stops and returns `nil`.

For each truthy condition result, `while` creates a fresh lexical child scope and evaluates the body in that scope.

The body uses normal body rules.

The body result is discarded after each iteration. When the loop stops, `while` returns `nil`.

Bindings created inside one iteration are not visible in subsequent iterations.

Outer bindings may be mutated with `set`.

```scheme
(def i 0)

(while (< i 3)
  (print i)
  (set i (+ i 1)))
; prints 0
; prints 1
; prints 2
; returns nil
```

A non-empty `while` body must end with an expression.

```scheme
(while cond
  (def x 10))
; error
```

### Fn

```scheme
(fn (params...)
  body-form...)
```

`fn` is an expression special form.

It creates an anonymous function that captures its lexical environment.

Calling the function creates a fresh function scope, binds parameters to argument values, evaluates the function body, and returns the body result.

```scheme
(fn (x)
  (+ x 1))
```

Function bodies use normal body rules.

```scheme
(fn (x)
  (print x)
  (+ x 1))
```

An empty function body returns `nil` when called.

```scheme
(fn ())
```

Function parameters have fixed arity.

Calling a function with the wrong number of arguments is an error.

Duplicate parameter names are an error.

### Set

```scheme
(set target expr)
```

`set` is an expression special form.

It mutates an existing place and returns the assigned value.

`set` never creates a new binding.

For name targets, `set` mutates the nearest visible binding with that name.

If the nearest visible binding is global, `set` mutates it only when that global binding is mutable.

Targeting a known immutable binding is a compile error. The value expression is not evaluated.

Supported targets:

```scheme
(set name value)
(set (receiver-expr index-expr) value)
```

Binding mutation:

```scheme
(def x 10)

(set x 20)
; 20

x
; 20
```

Setting an undefined binding is an error.

```scheme
(set missing 10)
; error
```

Supplied built-in global bindings are immutable and cannot be replaced with `set`.

```scheme
(set + (fn (a b) 999))
; error
```

Built-in names may still be shadowed by ordinary mutable bindings.

```scheme
(def + (fn (a b) 999))

(+ 1 2)
; 999

(set + (fn (a b) 123))

(+ 1 2)
; 123
```

```scheme
(set print (fn (value) nil))
; error
```

Built-in names may still be shadowed by ordinary mutable bindings.

```scheme
(def print (fn (value) nil))

(set print (fn (value) value))
; mutates the file binding
```

Vector slot mutation:

```scheme
(def v [10 20 30])

(set (v 1) 99)
; 99

(v 1)
; 99
```

For indexed `set`, evaluation order is:

```text
receiver expression
index expression
value expression
mutation
```

The receiver must evaluate to a mutable vector. The index must evaluate to an int.

## Closures

Functions capture lexical bindings from their surrounding scopes.

A closure sees the current value of a captured mutable binding when it is called.

```scheme
(def (make-adder n)
  (fn (x)
    (+ x n)))

(def add10 (make-adder 10))

(add10 5)
; 15
```

Closures capture bindings, not value snapshots.

```scheme
(def (make-counter)
  (def n 0)

  (fn ()
    (set n (+ n 1))
    n))

(def counter (make-counter))

(counter)
; 1

(counter)
; 2
```

Looking up an undefined name inside a closure is an error when that lookup is evaluated.

```scheme
(def f (fn () missing))

(f)
; error
```

## Data Types

### Vectors

Vectors are heterogeneous, growable, mutable, 0-indexed sequences of Wisp values.

Vector literals create fresh vectors.

```scheme
[10 20 30]
[]
```

Vectors may contain any Wisp value, including `nil`.

```scheme
[nil true 10 "dog"]
```

Vectors are callable by index.

```scheme
(def v [10 20 30])

(v 0)
; 10

(v 1)
; 20
```

Vector calls are normal calls, not special indexing syntax.

```scheme
([10 20 30] 2)
; 30
```

A vector call requires exactly one integer index.

An out-of-bounds vector index is an error.

### Lists

Lists are immutable runtime values.

Source lists are also the surface shape of Wisp forms.

`list` constructs list values at runtime.

```scheme
(list expr...)
```

Arguments evaluate left-to-right. The result is a fresh immutable list containing those values.

```scheme
(def x 10)

(list x (+ 1 2))
; (10 3)
```

`list` accepts zero or more arguments.

```scheme
(list)
; ()
```

Lists may contain any Wisp value, including `nil`.

```scheme
(list nil true 10 "dog")
; (nil true 10 dog)
```

### Numbers

Wisp has ints and floats.

Integer literals are signed base-10 integers.

Float literals are signed base-10 numbers with a decimal point.

```text
integer = ["-"], digit, {digit}
float   = ["-"], (
            digit, {digit}, ".", {digit}
          | ".", digit, {digit}
          )
```

Examples:

```scheme
10
-10
0
-0
1.5
-1.5
1.
.5
-.5
```

`+1` is not a number literal.

Exponent notation is not a number literal.

```scheme
1e3
1e-3
```

Hex, underscores, `nan`, and `inf` are not number literals.

```scheme
0x10
1_000
nan
inf
```

Integer literals must fit in the signed 64-bit integer range.

Float literals must fit in the runtime float range.

A numeric-looking atom that does not match the number grammar is a read error.

```scheme
-.
1abc
0x10
1_000
```

Normal non-numeric atoms are read as names.

```scheme
foo
foo.1
.
.nan
nan
inf
```

Integers are used for vector indexes and lengths.

Mixed int/float arithmetic promotes ints to floats as needed.

### Strings

Strings are immutable.

String literals use double quotes.

```scheme
"hello"
```

String escapes are not implemented.

A backslash inside a string is a read error.

A literal newline or carriage return inside a string is a read error.

Strings compare by contents.

```scheme
(= "dog" "dog")
; true
```

`len` returns the byte length of a string.

```scheme
(len "hello")
; 5
```

## Built-in Functions

Built-in functions are ordinary function values supplied by Wisp in the global environment.

They are called the same way user functions are called.

Supplied built-in global bindings are immutable.

Built-in function names are not reserved.

File or local definitions may shadow built-in functions.

`set` cannot replace a supplied built-in binding. A shadowing file or local binding remains mutable.

Arguments are evaluated left-to-right before the built-in is called.

An implementation may use dedicated bytecode for a direct call to a known supplied built-in, provided that observable behavior remains unchanged.

```scheme
(def + (fn (a b) 999))

(+ 1 2)
; 999
```

```scheme
(def add +)

(add 1 2)
; 3
```

### Arithmetic

```scheme
(+ a b ...)
(- a b ...)
(* a b ...)
(/ a b ...)
```

Arithmetic operations accept two or more numbers.

They reduce left-to-right.

```scheme
(+ 1 2 3)
; 6

(- 10 2 3)
; 5

(* 2 3 4)
; 24

(/ 20 2 5)
; 2.0
```

Zero-argument arithmetic is an error.

```scheme
(+)
; error
```

Unary arithmetic is an error.

```scheme
(- 1)
; error

(/ 2)
; error
```

`/` always returns a float.

```scheme
(/ 4 2)
; 2.0

(/ 5 2)
; 2.5
```

Dividing by zero is an error.

```scheme
(/ 1 0)
; error

(/ 1 0.0)
; error
```

`+`, `-`, and `*` return an int when all arguments are ints. They return a float when any argument is a float.

All-int arithmetic is checked after each left-to-right `+`, `-`, or `*` step. If an intermediate result does not fit in an int, evaluation is an error.

```scheme
(+ 1 2)
; 3

(+ 1 2.5)
; 3.5
```

### Vector Mutation

```scheme
(push vector value value...)
(pop vector)
```

`push` accepts a vector and one or more values.

Its first argument must produce a vector.

It evaluates the vector followed by every value from left to right. If argument evaluation succeeds, `push` appends each value from left to right, mutates the vector in place, and returns the vector.

```scheme
(def v [10 20])

(push v 30 40)
; [10 20 30 40]

v
; [10 20 30 40]
```

`pop` accepts exactly one argument, which must produce a vector.

It removes and returns the final value.

```scheme
(pop v)
; 40

v
; [10 20 30]
```

`pop` from an empty vector is an error.

### Boolean

```scheme
(not value)
```

`not` is an ordinary built-in function.

It accepts exactly one normally evaluated argument.

It returns `true` when the argument is falsey and `false` otherwise.

Only `nil` and `false` are falsey.

As an ordinary built-in, `not` follows normal global binding rules.

```scheme
(not nil)
; true

(not false)
; true

(not true)
; false

(not 0)
; false

(not "")
; false

(not [])
; false
```

### Equality

```scheme
(= a b)
```

`=` accepts two values and returns a bool.

Equality rules:

```text
nil equals nil.
bools compare by value.
numbers compare by numeric value.
strings compare by contents.
lists compare by identity.
vectors compare by identity.
functions compare by identity.
different non-numeric kinds are unequal.
```

Numeric equality treats equal int and float values as equal.

```scheme
(= 1 1.0)
; true
```

### Ordering

```scheme
(< a b)
(<= a b)
(> a b)
(>= a b)
```

Ordering comparisons accept two numbers and return a bool.

Mixed int/float comparison is allowed.

Non-number operands are an error.

```scheme
(< 1 2)
; true

(< 1 2.5)
; true

(< "a" "b")
; error
```

### Output

```scheme
(print value)
```

`print` writes the display representation of `value` followed by a newline and returns `nil`.

Strings print without quotes.

```scheme
(print "hello")
; prints:
; hello
```

Function values print as opaque function values.

```scheme
(print (fn () 10))
; prints:
; <function>
```

### Length

```scheme
(len value)
```

`len` accepts exactly one argument.

It accepts vectors and strings.

For vectors, it returns the number of elements.

For strings, it returns the byte length of the UTF-8 string.

```scheme
(len [10 20 30])
; 3

(len "hello")
; 5
```

## Display

Wisp display writes values in a readable form.

```text
nil       -> nil
true      -> true
false     -> false
strings   -> their text without quotes
lists     -> parenthesized values
vectors   -> bracketed values
functions -> <function>
```

Examples:

```scheme
(print nil)
; nil

(print true)
; true

(print "dog")
; dog

(print [1 2 3])
; [1 2 3]

(print (list 1 2 3))
; (1 2 3)
```

## Deferred Features

These features are intentionally not specified yet:

```text
quote
symbol values and symbol literals
eval
macros
source-as-data APIs
program-as-data APIs
read-only quoted aggregate data
```

Wisp uses s-expression syntax for programs, but the current surface does not expose full code-as-data semantics.

## Examples

### Local Scope

```scheme
(def x 10)

(do
  (def x 20)
  (print x)
  x)
; prints 20
; returns 20

x
; 10
```

### Ordered Definitions

```scheme
(do
  (print "start")
  (def x 10)
  (+ x 1))
; prints start
; returns 11
```

```scheme
(do
  (print x)
  (def x 10)
  nil)
; error
```

### Conditional Branches

```scheme
(def alive true)

(if alive
  "alive"
  "dead")
; "alive"
```

Use `do` when a branch needs local definitions.

```scheme
(if alive
  (do
    (def message "alive")
    (print message)
    message)
  "dead")
; prints alive
; returns "alive"
```

The branch-local binding does not escape.

```scheme
message
; error
```

### Looping

```scheme
(def i 0)

(while (< i 3)
  (print i)
  (set i (+ i 1)))
; prints 0
; prints 1
; prints 2
; returns nil
```

```scheme
(def done false)

(while (not done)
  (print "once")
  (set done true))
; prints once
; returns nil
```

### Functions and Mutation

```scheme
(def (make-counter)
  (def n 0)

  (fn ()
    (set n (+ n 1))
    n))

(def counter (make-counter))

(counter)
; 1

(counter)
; 2

(counter)
; 3
```

### Vectors

```scheme
(def v [10 20 30])

(v 1)
; 20

(set (v 1) 99)
; 99

(v 1)
; 99

(push v 123)
; [10 99 30 123]

(pop v)
; 123
```
