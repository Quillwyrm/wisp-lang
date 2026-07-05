# Rite Language Reference

This document describes the intended core surface of Rite.

Rite is a small eager Lisp with s-expression syntax, lexical scope, mutable bindings, immutable lists, mutable vectorss, maps, and first-class functions.

## Source Shape

A Rite file is a sequence of top-level forms evaluated in order.

```clojure
(def x 10)
(print x)
(+ x 1)
```

A file may contain only definitions.

```clojure
(def x 10)
(def y 20)
```

A file may be empty. File evaluation does not require a final expression result.

Newlines are whitespace.

Line comments start with `;` and continue to the end of the line.

```clojure
; comment
(def x 10) ; comment
```

## Lexical Elements

Rite source consists of names, literals, lists, vectors, maps, comments, and whitespace.

Names are non-delimiter atoms that are not literals or number literals.

Examples:

```clojure
x
player-name
+
<=
foo.1
```

`:` is a delimiter and begins a name string.

```clojure
:hp
; "hp"
```

The colon is not part of the resulting string. The tail must be non-empty.

```clojure
:
; error
```

Because `:` is a delimiter, `foo:bar` is read as the two adjacent forms `foo` and `:bar`.

The literal names are:

```text
nil
true
false
```

They produce literal values and cannot be used as binding names.

Special form names have fixed language meaning:

```text
def
set
do
if
while
fn
```

Special form names are reserved and cannot be used as binding names.

Built-in functions are immutable global function bindings supplied by Rite.

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
map
function
```

### Nil

`nil` is a value used for absence or no useful result.

`nil` is distinct from `false`.

`nil` is distinct from the empty list.

### Truthiness

Only `nil` and `false` are falsey.

Every other value is truthy, including:

```text
0
""
empty list values
[]
{}
```

## Forms

Rite source has two form categories:

```text
definitions
expressions
```

A definition creates a binding at file top level or in the current body.

An expression produces a value.

Definitions are valid only directly at file top level or inside bodies. A definition is not an expression.

```clojure
(def x 10)
```

Valid at file top level or in a body.

```clojure
(+ 1 (def x 10))
; error
```

Invalid because function arguments are expression positions.

```clojure
[(def x 10)]
; error
```

Invalid because vector elements are expression positions.

Use `do` when an expression position needs local definitions.

```clojure
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

```clojure
(do)
; nil
```

```clojure
(do
  (def x 10)
  x)
; 10
```

```clojure
(do
  (print "before")
  (def x 10)
  (+ x 1))
; 11
```

A non-empty body cannot end with a definition.

```clojure
(do
  (def x 10))
; error
```

File top level is program-like. A file may be empty, may contain only definitions, and may end with a definition.

## Names and Scope

Rite uses lexical scope.

Each file has its own file scope.

Rite has one global environment. Built-in functions are immutable bindings in the global environment.

Name lookup checks local body scopes first, then file scope, then the global environment.

A definition creates a mutable binding in the current scope. At file top level, this is the file scope. Inside `do` or `fn`, this is the current body scope.

A child scope can read visible bindings from parent scopes.

A child scope may define a name that shadows an outer binding.

A file-scope definition may shadow a global binding, including a built-in function.

A duplicate definition for the same name in the same scope is an error.

Bindings are ordered. A binding is visible only after its definition has been evaluated.

```clojure
(do
  x
  (def x 10)
  nil)
; error
```

```clojure
(do
  (def x 10)
  x)
; 10
```

A name lookup is an error if no visible binding exists.

## Definitions

### Value Definition

```clojure
(def name expr)
```

`def` is a definition form.

It evaluates `expr`, creates a new mutable binding named `name` in the current scope, and stores the value in that binding.

The new binding is visible after the `def` has evaluated.

```clojure
(def x 10)

x
; 10
```

A duplicate definition in the same scope is an error.

```clojure
(def x 1)
(def x 2)
; error
```

A local definition may shadow an outer binding.

```clojure
(def x 10)

(do
  (def x 20)
  x)
; 20

x
; 10
```

Because `def` is not an expression, it cannot be used as an argument, branch, vector element, initializer, or final body result.

```clojure
(def x (def y 10))
; error
```

```clojure
(if alive
  (def status "alive")
  "dead")
; error
```

### Named Function Definition

```clojure
(def (name params...)
  body-form...)
```

A named function definition is a definition form.

It defines `name` as a function in the current scope.

```clojure
(def (inc x)
  (+ x 1))

(inc 10)
; 11
```

It has the same user-visible meaning as defining the name with `fn`.

```clojure
(def inc
  (fn (x)
    (+ x 1)))
```

The function body follows normal body rules.

The function body is not evaluated when the named function is defined. It is evaluated only when the function is called.

An empty named function body returns `nil` when called.

```clojure
(def (noop))

(noop)
; nil
```

Named functions may call themselves recursively.

```clojure
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

```clojure
nil
true
false
10
1.5
"hello"
:hp
```

A name string is ordinary string syntax for delimiter-free text.

```clojure
(= :hp "hp")
; true
```

### Names

A name expression reads the current visible binding for that name.

```clojure
(def x 10)

x
; 10
```

Reading an undefined name is an error.

### Vector Literals

A vector literal creates a fresh mutable vector.

```clojure
[expr expr expr]
```

Elements are expressions evaluated left-to-right.

```clojure
(def x 10)

[1 x (+ 1 2)]
; [1 10 3]
```

Definitions are not valid inside vector literals.

```clojure
[(def x 10)]
; error
```

### Map Literals

A map literal creates a fresh mutable map.

```clojure
{key-expr value-expr ...}
```

It must contain complete key/value pairs. For each pair, the key expression is
evaluated first, then the value expression, then the entry is inserted. Pairs
are processed left-to-right.

```clojure
{:hp 100 :name "Rook"}
```

Equal keys are replaced by later entries.

```clojure
{:hp 100 :hp 90}
; {hp 90}
```

Definitions are not valid in key or value expression positions.

### List Forms

A non-empty source list in expression position is evaluated as a form.

```clojure
(head arg arg)
```

If the bare head is a special form name, that special form controls evaluation.

```clojure
(if alive "alive" "dead")
(fn (x) (+ x 1))
(do (def x 10) x)
```

Otherwise, the head and arguments follow normal call evaluation.

An unresolved callee name is an error.

```clojure
(+ 1 2)
; 3
```

Built-in functions may be read and called through other bindings.

```clojure
(def add +)

(add 1 2)
; 3
```

Built-in function names may be shadowed.

```clojure
(def + (fn (a b) 999))

(+ 1 2)
; resolves + to the file binding and calls its value
```

An empty source list in expression position is an error.

```clojure
()
; error
```

## Calls

A call has this shape:

```clojure
(callee arg...)
```

The callee expression is evaluated first.

Arguments are evaluated left-to-right.

The resulting callee value is called with the resulting argument values.

Callable values:

```text
function
vector
map
```

Calling any other value is an error.

A function call checks arity, creates a function scope, binds parameters, evaluates the function body, and returns the body result.

Vector calls index the vector.

```clojure
(def v [10 20 30])

(v 1)
; 20

([10 20 30] 2)
; 30
```

A vector call requires exactly one integer index.

An out-of-bounds vector index is an error.

Map calls look up one key.

```clojure
(def player {:hp 100})

(player :hp)
; 100

(player :missing)
; nil
```

A map call requires exactly one non-`nil` key. A missing valid key returns `nil`.

## Special Forms

Special forms are language forms with special evaluation rules.

A special form is recognized only when its name appears as the head of an evaluated list form.

### Do

```clojure
(do
  body-form...)
```

`do` is an expression special form.

It creates a fresh lexical child scope, evaluates its body in that scope, and returns the body result.

```clojure
(do)
; nil
```

```clojure
(do
  (def x 10)
  (+ x 1))
; 11
```

Bindings created inside `do` are not directly visible outside that scope.

```clojure
(do
  (def x 10)
  x)
; 10

x
; error
```

A non-empty `do` body must end with an expression.

```clojure
(do
  (def x 10))
; error
```

### If

```clojure
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

```clojure
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

```clojure
(if alive
  (def status "alive")
  "dead")
; error
```

Use `do` when a branch needs local definitions or multiple forms.

```clojure
(if alive
  (do
    (def message "alive")
    (print message)
    message)
  "dead")
; prints alive
; returns "alive"
```

The binding is not directly visible outside the branch's `do` scope.

```clojure
message
; error
```

### While

```clojure
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

```clojure
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

```clojure
(while cond
  (def x 10))
; error
```

### Fn

```clojure
(fn (params...)
  body-form...)
```

`fn` is an expression special form.

It creates an anonymous function that captures its lexical environment.

Calling the function creates a fresh function scope, binds parameters to argument values, evaluates the function body, and returns the body result.

```clojure
(fn (x)
  (+ x 1))
```

Function bodies use normal body rules.

```clojure
(fn (x)
  (print x)
  (+ x 1))
```

An empty function body returns `nil` when called.

```clojure
(fn ())
```

Function parameters have fixed arity.

Calling a function with the wrong number of arguments is an error.

Duplicate parameter names are an error.

### Set

```clojure
(set target expr)
```

`set` is an expression special form.

It mutates an existing place and returns the assigned value.

`set` never creates a new binding.

For name targets, `set` mutates the nearest visible binding with that name.

If the nearest visible binding is global, `set` mutates it only when that global binding is mutable.

Targeting a known immutable binding is a compile error. The value expression is not evaluated.

Supported targets:

```clojure
(set name value)
(set (receiver-expr index-expr) value)
```

Binding mutation:

```clojure
(def x 10)

(set x 20)
; 20

x
; 20
```

Setting an undefined binding is an error.

```clojure
(set missing 10)
; error
```

Supplied built-in global bindings are immutable and cannot be replaced with `set`.

```clojure
(set + (fn (a b) 999))
; error
```

Built-in names may still be shadowed by mutable bindings.

```clojure
(def + (fn (a b) 999))

(+ 1 2)
; 999

(set + (fn (a b) 123))

(+ 1 2)
; 123
```

```clojure
(set print (fn (value) nil))
; error
```

Built-in names may still be shadowed by mutable bindings.

```clojure
(def print (fn (value) nil))

(set print (fn (value) value))
; mutates the file binding
```

Indexed mutation:

```clojure
(def v [10 20 30])

(set (v 1) 99)
; 99

(v 1)
; 99
```

Map mutation inserts, replaces, or deletes an entry.

```clojure
(def player {:hp 100})

(set (player :hp) 90)
; 90

(set (player :name) "Rook")
; Rook

(set (player :hp) nil)
; nil
```

For indexed `set`, evaluation order is:

```text
receiver expression
index expression
value expression
mutation
```

The receiver must evaluate to a mutable vector or map.

For vectors, the index must evaluate to an in-range int.

For maps, the key must be non-`nil`. A non-`nil` value inserts or replaces the
entry. Assigning `nil` deletes it.

## Closures

Functions capture lexical bindings from their surrounding scopes.

A closure sees the current value of a captured mutable binding when it is called.

```clojure
(def (make-adder n)
  (fn (x)
    (+ x n)))

(def add10 (make-adder 10))

(add10 5)
; 15
```

Closures capture bindings, not value snapshots.

```clojure
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

```clojure
(def f (fn () missing))

(f)
; error
```

## Data Types

### Vectors

Vectors are heterogeneous, growable, mutable, 0-indexed sequences of Rite values.

Vector literals create fresh vectors.

```clojure
[10 20 30]
[]
```

Vectors may contain any Rite value, including `nil`.

```clojure
[nil true 10 "dog"]
```

Vectors are callable by index.

```clojure
(def v [10 20 30])

(v 0)
; 10

(v 1)
; 20
```

Vectors are indexed through call syntax using normal call evaluation.

```clojure
([10 20 30] 2)
; 30
```

A vector call requires exactly one integer index.

An out-of-bounds vector index is an error.

### Maps

Maps are heterogeneous mutable associative containers.

```clojure
{}
{:hp 100 :name "Rook"}
```

Any runtime value except `nil` may be a key.

Map key equality follows Rite equality:

```text
bools compare by value
numbers compare by numeric value
strings compare by contents
lists, vectors, maps, and functions compare by identity
```

Maps cannot store `nil`. Assigning `nil` deletes the entry, and looking up a
missing key returns `nil`.

Map display order is unspecified.

### Lists

Lists are immutable runtime values.

Source lists are the surface shape of Rite forms, not runtime list literals.

Lists may contain any Rite value, including `nil`.

### Numbers

Rite has ints and floats.

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

```clojure
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

```clojure
1e3
1e-3
```

Hex, underscores, `nan`, and `inf` are not number literals.

```clojure
0x10
1_000
nan
inf
```

Integer literals must fit in the signed 64-bit integer range.

Float literals must fit in the runtime float range.

A numeric-looking atom that does not match the number grammar is a read error.

```clojure
-.
1abc
0x10
1_000
```

Normal non-numeric atoms are read as names.

```clojure
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

```clojure
"hello"
```

A backslash inside a string is a read error.

A literal newline or carriage return inside a string is a read error.

Strings compare by contents.

```clojure
(= "dog" "dog")
; true
```

`len` returns the byte length of a string.

```clojure
(len "hello")
; 5
```

Name strings produce ordinary string values without including the leading colon.

```clojure
:player-name
; "player-name"
```

## Built-in Functions

Built-in functions are function values supplied by Rite in the global environment.

They are called the same way user functions are called.

Supplied built-in global bindings are immutable.

Built-in function names are not reserved.

File or local definitions may shadow built-in functions.

`set` cannot replace a supplied built-in binding. A shadowing file or local binding remains mutable.

Arguments are evaluated left-to-right before the built-in is called.

| Function | Arity | Returns |
| --- | ---: | --- |
| `+` | 2+ values; all numbers or at least one string | int, float, or string |
| `-`, `*` | 2+ numbers | int or float |
| `/` | 2+ numbers | float |
| `%` | 2 numbers | int or float |
| `=`, `!=` | 2 values | bool |
| `<`, `<=`, `>`, `>=` | 2 numbers | bool |
| `not` | 1 value | bool |
| `nil?`, `bool?`, `num?`, `int?`, `float?` | 1 value | bool |
| `str?`, `vec?`, `map?`, `fn?` | 1 value | bool |
| `len` | 1 value | int |
| `copy` | 1 vector or map | fresh vector or map |
| `clear` | 1 vector or map | same emptied vector or map |
| `push` | vector and 1+ values | vector |
| `pop` | 1 vector | value |
| `insert` | vector, index, value | vector |
| `remove` | vector, index | removed value |
| `slice` | vector, start, count | fresh vector |
| `keys`, `vals`, `pairs` | 1 map | fresh vector |
| `merge` | 2+ maps | fresh map |
| `type` | 1 value | string |
| `print` | 0+ values | nil |
| `write` | 0+ values | nil |
| `assert` | 1 or 2 values | nil or ends the current run |
| `error` | 1 value | ends the current run |

```clojure
(def + (fn (a b) 999))

(+ 1 2)
; 999
```

```clojure
(def add +)

(add 1 2)
; 3
```

### Arithmetic

```clojure
(+ a b ...)
(- a b ...)
(* a b ...)
(/ a b ...)
(% a b)
```

`+` accepts two or more values.

If every argument is a number, `+` returns their numeric sum.

If any argument is a string, `+` returns a fresh string containing the display text of every argument in order.

```clojure
(+ "hp: " 100)
; "hp: 100"

(+ 1 2 "x" 3)
; "12x3"

(+ "value: " true)
; "value: true"
```

Without a string argument, every argument to `+` must be a number.

`-`, `*`, and `/` accept two or more numbers.

Numeric arithmetic reduces left-to-right.

```clojure
(+ 1 2 3)
; 6

(- 10 2 3)
; 5

(* 2 3 4)
; 24

(/ 20 2 5)
; 2.0
```

`%` accepts exactly two numbers and computes floor-style modulo.

```clojure
(% 13 4)
; 1

(% -13 4)
; 3

(% 13 -4)
; -3

(% -1 8)
; 7
```

Int modulo returns an int. If either argument is a float, modulo returns a float.

Modulo by zero is an error.

Zero-argument arithmetic is an error.

```clojure
(+)
; error
```

Unary arithmetic is an error.

```clojure
(- 1)
; error

(/ 2)
; error
```

`/` always returns a float.

```clojure
(/ 4 2)
; 2.0

(/ 5 2)
; 2.5
```

Dividing by zero is an error.

```clojure
(/ 1 0)
; error

(/ 1 0.0)
; error
```

With numeric arguments, `+`, `-`, and `*` return an int when every argument is an int. They return a float when any argument is a float.

All-int arithmetic is checked after each left-to-right `+`, `-`, or `*` step. If an intermediate result does not fit in an int, evaluation is an error.

```clojure
(+ 1 2)
; 3

(+ 1 2.5)
; 3.5
```

### Vector Mutation

```clojure
(push vector value value...)
(pop vector)
(insert vector index value)
(remove vector index)
(slice vector start count)
```

`push` accepts a vector and one or more values.

Its first argument must produce a vector.

It evaluates the vector followed by every value from left to right. If argument evaluation succeeds, `push` appends each value from left to right, mutates the vector in place, and returns the vector.

```clojure
(def v [10 20])

(push v 30 40)
; [10 20 30 40]

v
; [10 20 30 40]
```

`pop` accepts exactly one argument, which must produce a vector.

It removes and returns the final value.

```clojure
(pop v)
; 40

v
; [10 20 30]
```

`pop` from an empty vector is an error.

`insert` mutates a vector by inserting a value before the given index and
shifting later elements right. The index may range from zero through the vector
length. It returns the vector.

```clojure
(def v [10 30])

(insert v 1 20)
; [10 20 30]
```

`remove` removes and returns the value at an index, shifting later elements
left. Its index must be within the vector.

```clojure
(remove v 1)
; 20

v
; [10 30]
```

`slice` returns a fresh shallow vector containing `count` elements starting at
`start`. The complete range must be within the source vector.

```clojure
(slice [10 20 30 40] 1 2)
; [20 30]
```

### Map Operations

```clojure
(keys map)
(vals map)
(pairs map)
(merge map map...)
```

`keys` and `vals` return fresh vectors containing the entries of a map.

`pairs` returns a fresh vector of fresh `[key value]` vectors.

Map traversal order is unspecified. Within one `pairs` result, each key remains
associated with its value.

`merge` accepts two or more maps and returns a fresh map. Inputs are unchanged,
and entries from later maps replace equal keys from earlier maps.

```clojure
(merge {:hp 100 :speed 4}
       {:speed 8 :name "goblin"})
; {hp 100 speed 8 name goblin}
```

### Type

```clojure
(type value)
```

`type` accepts exactly one value and returns its type name as a string.

```text
nil      -> "nil"
bool     -> "bool"
int      -> "int"
float    -> "float"
string   -> "string"
list     -> "list"
vector   -> "vector"
map      -> "map"
function -> "function"
```

Native and Rite functions both have the public type name `"function"`.

### Predicates

```clojure
(nil? value)
(bool? value)
(num? value)
(int? value)
(float? value)
(str? value)
(vec? value)
(map? value)
(fn? value)
```

Each predicate accepts exactly one value and reports whether it belongs to that
type. `num?` accepts both ints and floats. `fn?` accepts every public function
value.

### Length

```clojure
(len value)
```

`len` accepts exactly one argument.

It accepts vectors, maps, and strings.

For vectors, it returns the number of elements.

For maps, it returns the number of entries.

For strings, it returns the byte length of the UTF-8 string.

```clojure
(len [10 20 30])
; 3

(len {:hp 100 :name "Rook"})
; 2

(len "hello")
; 5
```

### Copy and Clear

```clojure
(copy collection)
(clear collection)
```

Both functions accept vectors and maps.

`copy` returns a fresh shallow collection. Nested vectors, maps, and other
objects remain shared.

`clear` removes every element or entry from the existing collection and returns
that same collection.

```clojure
(def original [1 [2]])
(def duplicate (copy original))

(= original duplicate)
; false

(= (original 1) (duplicate 1))
; true

(clear duplicate)
; []
```

### Boolean

```clojure
(not value)
```

`not` is a built-in function.

It accepts exactly one normally evaluated argument.

It returns `true` when the argument is falsey and `false` otherwise.

Only `nil` and `false` are falsey.

```clojure
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

```clojure
(= a b)
(!= a b)
```

`=` and `!=` accept two values and return a bool.

`!=` is the negation of `=`.

Equality rules:

```text
nil equals nil.
bools compare by value.
numbers compare by numeric value.
strings compare by contents.
lists compare by identity.
vectors compare by identity.
maps compare by identity.
functions compare by identity.
different non-numeric kinds are unequal.
```

Numeric equality treats equal int and float values as equal.

Mixed numeric equality converts the int to a float before comparison.

```clojure
(= 1 1.0)
; true
```

### Ordering

```clojure
(< a b)
(<= a b)
(> a b)
(>= a b)
```

Ordering comparisons accept two numbers and return a bool.

Mixed int/float comparison is allowed.

Mixed numeric ordering converts the int to a float before comparison.

Non-number operands are an error.

```clojure
(< 1 2)
; true

(< 1 2.5)
; true

(< "a" "b")
; error
```

### Output

```clojure
(print value...)
(write value...)
```

`print` writes each display value separated by spaces, writes a final newline, and returns `nil`.

With no arguments, `print` writes a newline.

`write` writes each display value without separators or a final newline and returns `nil`.

Strings print without quotes.

```clojure
(print "hello" 10)
; prints:
; hello 10

(write "x=" 10)
; prints:
; x=10
```

Function values print as opaque function values.

```clojure
(print (fn () 10))
; prints:
; <function>
```

### Errors

```clojure
(assert condition)
(assert condition message)
(error message)
```

`assert` accepts a condition and an optional message.

Its arguments are evaluated normally.

If the condition is truthy, `assert` returns `nil`.

If the condition is falsey, `assert` ends the current run. Without a message, the diagnostic is `assertion failed`. With a message, the diagnostic is `assertion failed: ` followed by the message value's display text.

```clojure
(assert (< hp max-hp) "hp out of range")
```

`error` accepts exactly one value and ends the current run with a runtime diagnostic using that value's display text.

```clojure
(error "unreachable")
(error [1 2 3])
```

## Display

Rite display writes values in a readable form.

```text
nil       -> nil
true      -> true
false     -> false
strings   -> their text without quotes
lists     -> parenthesized values
vectors   -> bracketed values
maps      -> braced key/value pairs
functions -> <function>
```

Examples:

```clojure
(print nil)
; nil

(print true)
; true

(print "dog")
; dog

(print [1 2 3])
; [1 2 3]

(print {:hp 100 :name "Rook"})
; {hp 100 name Rook}
```

## Examples

### Local Scope

```clojure
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

```clojure
(do
  (print "start")
  (def x 10)
  (+ x 1))
; prints start
; returns 11
```

```clojure
(do
  (print x)
  (def x 10)
  nil)
; error
```

### Conditional Branches

```clojure
(def alive true)

(if alive
  "alive"
  "dead")
; "alive"
```

Use `do` when a branch needs local definitions.

```clojure
(if alive
  (do
    (def message "alive")
    (print message)
    message)
  "dead")
; prints alive
; returns "alive"
```

The binding is not directly visible outside the branch's `do` scope.

```clojure
message
; error
```

### Looping

```clojure
(def i 0)

(while (< i 3)
  (print i)
  (set i (+ i 1)))
; prints 0
; prints 1
; prints 2
; returns nil
```

```clojure
(def done false)

(while (not done)
  (print "once")
  (set done true))
; prints once
; returns nil
```

### Functions and Mutation

```clojure
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

```clojure
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

### Maps

```clojure
(def player {:hp 100 :name "Rook"})

(player :hp)
; 100

(set (player :hp) 90)
; 90

(set (player :name) nil)
; nil

(len player)
; 1
```
