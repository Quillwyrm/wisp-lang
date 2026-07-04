# Rite Control and Fallback Forms

## `and` / `or`

`and` and `or` are boolean composition forms.

They short-circuit, but they do not select and return arbitrary operand values.

```scheme
(and a b c) ; bool
(or a b c)  ; bool
```

Truthiness:

```text
nil and false are falsey.
Everything else is truthy.
```

Semantics:

```scheme
(and a b c)
;; Evaluates left to right.
;; Stops at the first falsey value.
;; Returns true if all operands are truthy.
;; Returns false otherwise.

(or a b c)
;; Evaluates left to right.
;; Stops at the first truthy value.
;; Returns true if any operand is truthy.
;; Returns false otherwise.
```

Examples:

```scheme
(and true true)
;; true

(and true nil)
;; false

(or nil false "hello")
;; true
```

Important rule:

```text
and/or are not fallback operators.
```

Do not use `or` for defaults:

```scheme
(or (config :name) "unnamed")
;; returns bool, not the selected value
```

Use `??` for nil fallback.

## `??`

`??` is nil-coalescing fallback.

```scheme
(?? value fallback...) ; value
```

It evaluates operands left to right and returns the first value that is not nil.

If every operand is nil, it returns nil.

`false` is a real value and must not trigger fallback.

```scheme
(?? nil "fallback")
;; "fallback"

(?? false "fallback")
;; false

(?? nil nil 10)
;; 10

(?? nil nil)
;; nil
```

Main uses:

```scheme
(def name (?? (player :name) "unnamed"))
(def home (?? (os/env "HOME") "."))
(def debug (?? (config :debug) false))
```

Design intent:

```text
?? handles absence.
if/cond handle branching.
and/or handle boolean composition.
```

`??` should not catch errors and should not treat false, zero, empty strings, or empty collections as missing.

Only nil means missing.

## `cond`

`cond` is multi-way conditional branching.

```scheme
(cond
  test expr
  test expr
  ...)
```

Tests are evaluated top to bottom.

The first truthy test wins.

The matching expression is evaluated and returned.

If no test matches, `cond` returns nil.

```scheme
(cond
  err
    (io/print-err err)

  (nil? line)
    (print "EOF")

  :else
    (print line))
```

`:else` is not special syntax. It is a name-string literal that evaluates to a truthy string value. It is the recommended default-branch idiom.

Equivalent idea:

```scheme
(cond
  err         (io/print-err err)
  (nil? line) (print "EOF")
  :else       (print line))
```

Semantics of the final branch:

```scheme
:else
;; evaluates to "else"
;; "else" is truthy
;; therefore this branch always matches if reached
```

Branches with multiple forms should use `do`:

```scheme
(cond
  err
    (do
      (io/print-err "input error:" err)
      (os/exit 1))

  (nil? line)
    (do
      (print "bye")
      (os/exit 0))

  :else
    (print "you typed:" line))
```

`cond` is preferred over deeply nested `if` chains.

```scheme
(cond
  (= command "quit") (os/exit 0)
  (= command "help") (print-help)
  (= command "run")  (run)
  :else              (print "unknown command:" command))
```

## `case`

`case` is optional later syntax for one-subject equality dispatch.

It is not needed initially because `cond` can express the same thing.

Possible shape:

```scheme
(case subject
  match expr
  match expr
  :else fallback)
```

Example:

```scheme
(case command
  "quit" (os/exit 0)
  "help" (print-help)
  "run"  (run)
  :else  (print "unknown command:" command))
```

Possible semantics:

```text
The subject is evaluated once.
Each match expression is evaluated top to bottom.
Each match is compared with the subject using =.
The first equal match wins.
The matching expression is evaluated and returned.
If no match succeeds and there is no :else branch, returns nil.
```

A `cond` equivalent:

```scheme
(cond
  (= command "quit") (os/exit 0)
  (= command "help") (print-help)
  (= command "run")  (run)
  :else              (print "unknown command:" command))
```

Recommended staging:

```text
Add cond first.
Delay case until real scripts show repeated one-subject dispatch.
```

## Control Surface Summary

```text
if
  two-way branch

do
  sequence expression

cond
  multi-way branch

case
  optional later one-subject equality dispatch

and/or
  boolean composition, short-circuiting, bool result

??
  nil-only fallback
```

This keeps intent separated:

```text
Boolean logic:
  and / or

Absence fallback:
  ??

Two-way branching:
  if

Multi-way branching:
  cond

Subject dispatch:
  case, later if needed
```
