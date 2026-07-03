The MVP builtin set we discussed, excluding `and` / `or` / `else`, is this:

| Builtin |         Arity | Return       | Opcode fast-path?     | Notes                                                         |
| ------- | ------------: | ------------ | --------------------- | ------------------------------------------------------------- |
| `+`     |    2+ numbers | int or float | yes                   | Variadic reducer. Runtime error on under-arity/type/overflow. |
| `-`     |    2+ numbers | int or float | yes                   | No unary negation for now.                                    |
| `*`     |    2+ numbers | int or float | yes                   | Runtime error on int overflow.                                |
| `/`     |    2+ numbers | float        | yes                   | Division by zero runtime error.                               |
| `%`     |     2 numbers | int or float | yes                   | Floor-style modulo recommended.                               |
| `=`     |      2 values | bool         | yes                   | Value equality.                                               |
| `<`     |     2 numbers | bool         | yes                   | Numeric ordering.                                             |
| `<=`    |     2 numbers | bool         | yes                   | Numeric ordering.                                             |
| `>`     |     2 numbers | bool         | yes                   | Numeric ordering.                                             |
| `>=`    |     2 numbers | bool         | yes                   | Numeric ordering.                                             |
| `not`   |       1 value | bool         | yes                   | Uses Wisp truthiness.                                         |
| `len`   |       1 value | int          | yes                   | Vector length, string byte length.                            |
| `push`  | vector, value | vector       | yes, exact arity only | Mutates vector, returns vector.                               |
| `pop`   |        vector | value        | yes, exact arity only | Mutates vector, returns removed value.                        |
| `print` |     0+ values | nil          | no                    | Display values, space-separated, newline.                     |
| `write` |     0+ values | nil          | no                    | Display values, no separator, no newline.                     |

That is the clean MVP.

## Opcode-lowered group

Fast-path these direct known builtin calls:

```scheme
(+ ...)
(- ...)
(* ...)
(/ ...)
(% ...)
(= a b)
(< a b)
(<= a b)
(> a b)
(>= a b)
(not x)
(len x)
(push v x)
(pop v)
```

But still keep them as **ordinary native builtin function values**. The opcode is only the direct-call optimization.

So:

```scheme
(def my-add +)
(my-add 1 2)
```

works as ordinary native call, not opcode.

Direct:

```scheme
(+ 1 2)
```

can lower to `ADD`.

## Do not opcode-lower I/O

Do not make opcodes for:

```scheme
(print ...)
(write ...)
```

I/O cost dominates. A print/write opcode is VM clutter for no useful win.

They should just be native builtins.

## `%` semantics

Add `%` as floor-style modulo:

```text
(% a b) = a - b * floor(a / b)
```

Rules:

```text
exactly 2 numbers
division by zero is runtime error
int % int returns int
float involved returns float
result follows divisor direction
```

Examples:

```scheme
(% 13 4)
; 1

(% -13 4)
; 3

(% 13 -4)
; -3

(% -13 -4)
; -1

(% 10.5 3)
; 1.5
```

That is the best scripting/game/tool behavior because wraparound works:

```scheme
(% -1 8)
; 7
```

Do **not** add `rem` yet. If you later need truncating/C-style remainder, add `rem` in a math module or later core pass.

## `print` / `write`

I’d make both variadic now:

```scheme
(print)
; newline

(print "hp" 10)
; hp 10\n

(write "hp=" 10)
; hp=10
```

Rules:

```text
print: display each value, spaces between values, newline after all values, returns nil
write: display each value, no separator, no newline, returns nil
```

That gives you both human logging and raw-ish output composition without string concat pressure.

## `list`

Do **not** add `list` in this pass.

Even though the ref currently mentions it, runtime lists are not pulling much weight until quote/rest/destructuring/macros or list APIs exist. Vectors are the practical sequence type right now. The current ref still has `list`, but we already identified that as something to de-emphasize or defer. 

## Final MVP builtin batch

I’d implement in this order:

```text
1. not
2. = < <= > >=
3. len
4. write + variadic print
5. %
6. opcodes for %, comparisons, not, len
```

Arithmetic and `push/pop` are already in the right opcode-backed direction.
