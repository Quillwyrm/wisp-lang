# Rite Function Architecture Notes

This document is the current function/closure plan for Rite.

It replaces the older delayed-`def` / `slot_initialized` direction. Ordinary `def` stays ordered and simple. Self-recursion is supported either manually with an existing binding plus `set`, or later through named function definition sugar that expands to the same recursive-binding pattern.

---

## Current Source Facts

Current `rite.odin` has:

```odin
Value :: union {
	bool,
	i64,
	f64,
	^Object,
}
```

The zero value of `Value` is Rite `nil`.

Current finished code is:

```odin
Code :: struct {
	bytecode:         [dynamic]u32,
	constants:        [dynamic]Value,
	frame_slot_count: int,
}
```

Current VM state is:

```odin
VM :: struct {
	slots:        [dynamic]Value,
	globals:      [dynamic]GlobalBinding,
	symbols:      [dynamic]^SymbolObject,
	error_string: string,
}
```

Current local binding metadata is exactly:

```odin
LocalBinding :: struct {
	symbol: ^SymbolObject,
	slot:   int,
}
```

Current compiler state owns scope tracking:

```odin
Compiler := struct {
	failed: bool,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	current_scope_local_start: int,
	next_slot:                 int,
}{}
```

Preserve this division:

```text
LocalBinding says: symbol -> slot.

CodeBuilder/compiler state tracks:
  local_count
  current_scope_local_start
  next_slot
```

Do not add scope depth to `LocalBinding`.

Do not add captured flags to `LocalBinding`.

Do not add runtime initialization state to `LocalBinding`.

---

## Implementation Cut

Implement now:

```text
function values
file-as-root-Code
call frames
upvalues
closures
ordinary fn form
```

Leave for later:

```text
named recursive function definition sugar
modules
import/export
REPL persistence
map namespace sugar
math:square
quote/eval/macros
```

Reason:

```text
fn is the primitive function value form.
file-as-root-Code and call frames are required for real functions.
closures require upvalues.
modules and REPL are later loading/lifetime policy layers.
named function def is syntax over an existing function substrate.
```

---

## Ordinary `def` Semantics

Keep ordinary `def` ordered.

```scheme
(def name expr)
```

Meaning:

```text
evaluate/compile expr using currently visible bindings
then create name in the current scope
```

The new binding is not visible inside its own RHS.

So:

```scheme
(def x x)
```

means RHS `x` resolves to an already-existing outer/global `x` if one exists. If no such binding exists, it is an undefined-name error.

There is no pending binding state.

There is no uninitialized local state.

There is no `slot_initialized` array.

Current local read lowering can remain slot movement.

---

## Self-Recursion Model

Ordinary function-valued `def` is not self-recursive by itself:

```scheme
(def fact
  (fn (n)
    (fact (- n 1))))
```

This only works if `fact` already resolves to an existing binding while the `fn` body is compiled.

Manual recursive binding is:

```scheme
(def fact nil)

(set fact
  (fn (n)
    (if (= n 0)
      1
      (* n (fact (- n 1))))))
```

This works because:

```text
(def fact nil) creates the binding first.
The later set RHS compiles a function body where fact is already visible.
The function captures/uses that binding.
set replaces nil with the function object.
Recursive calls read the same binding, now containing the function.
```

Later named function definition sugar should use this recursive-binding shape.

```scheme
(def (fact n)
  (if (= n 0)
    1
    (* n (fact (- n 1)))))
```

Equivalent semantics:

```scheme
(def fact nil)
(set fact (fn (n) ...))
```

The compiler can implement it directly as one special form later:

```text
claim/publish fact binding
store nil or placeholder value
compile/create function with fact visible
store FunctionObject into fact slot
```

This means named function definition is recursive function-binding sugar, not pure textual sugar for ordinary `(def fact (fn ...))`.

That is acceptable and direct.

---

## Core Semantic Model

## File is root Code

A file compiles to root `Code`.

A `fn` compiles to child `Code`.

```text
file source -> root Code
fn source   -> child Code
```

Running a file means running root `Code` in a root `CallFrame`.

Calling a function means running child `Code` in a new `CallFrame`.

One executable-body model:

```text
CodeBuilder builds Code.
Code is fixed executable data.
FunctionObject pairs Code with runtime upvalues.
CallFrame runs Code.
```

## Top-level defs are root locals

Top-level `def` bindings are local slots in the root Code.

```scheme
(def x 10)

(def f
  (fn ()
    x))
```

`x` is a root local slot.

`f` is a root local slot.

`f` captures `x` because it references `x`.

Functions do not capture the whole file scope.

They capture only referenced outer bindings.

## Closures capture bindings

A closure captures binding storage, not a value snapshot.

```scheme
(def make-counter
  (fn ()
    (def n 0)

    (fn ()
      (set n (+ n 1))
      n)))

(def c (make-counter))

(c) ; 1
(c) ; 2
```

The returned function and the `set` refer to the same captured `n` storage.

---

## CodeBuilder

Replace the single global `Active_Code` / singleton compiler shape with builder state for the active Code being compiled.

Conceptual target:

```odin
CodeBuilder :: struct {
	bytecode:    [dynamic]u32,
	constants:   [dynamic]Value,
	child_codes: [dynamic]^Code,

	frame_slot_count: int,
	param_count:      int,

	local_bindings: [MAX_FRAME_SLOTS]LocalBinding,
	local_count:    int,

	current_scope_local_start: int,
	next_slot:                 int,

	upvalue_descs:   [dynamic]UpvalueDesc,
	upvalue_symbols: [dynamic]^SymbolObject,
}
```

`upvalue_symbols` is compile-only dedupe state.

It prevents repeated uses of the same captured name from creating duplicate upvalues in one function.

A package-level active builder stack is fine:

```text
code_builders: [dynamic]CodeBuilder
```

Do not introduce a manager/context wrapper around it unless there is a real lifetime boundary that needs a named object.

---

## Code

Finished Code:

```odin
Code :: struct {
	bytecode:    []u32,
	constants:   []Value,
	child_codes: []^Code,

	frame_slot_count: int,
	param_count:      int,

	upvalue_descs: []UpvalueDesc,
}
```

Builder arrays are mutable.

Finished Code is runtime-read data.

Use slices for finalized runtime-read data if ownership is handled deliberately.

`Code` bytecode is fixed.

`Code` constants are fixed.

`Code` child-code list is fixed.

`Code` upvalue descriptor list is fixed.

Per-instance captured values live on `FunctionObject`, not on `Code`.

---

## FunctionObject

Add a real Rite function object.

```odin
FunctionObject :: struct {
	header: Object,
	code:   ^Code,

	upvalues: []^Upvalue,
}
```

A `FunctionObject` is a runtime value.

`Code` is fixed executable data.

Many `FunctionObject`s may share the same `Code`.

Each `FunctionObject` has its own resolved upvalue array.

Example:

```scheme
(def make-adder
  (fn (n)
    (fn (x)
      (+ x n))))

(def add10 (make-adder 10))
(def add20 (make-adder 20))
```

The inner function Code is shared.

`add10` and `add20` have different runtime upvalues for `n`.

---

## CallFrame

Add call frames.

```odin
CallFrame :: struct {
	code:     ^Code,
	upvalues: []^Upvalue,

	instruction_index: int,

	slot_base:         int,
	caller_slot_count: int,
}
```

Operands are frame-relative.

```text
absolute_slot = frame.slot_base + operand_slot
```

## Call layout

Caller evaluates:

```text
callee in slot B
arg0   in slot B + 1
arg1   in slot B + 2
...
```

Callee frame:

```text
slot_base = B + 1
local slot 0 = arg0
local slot 1 = arg1
...
```

Return target:

```text
caller result slot = frame.slot_base - 1
```

No `result_slot` field is needed.

`caller_slot_count` restores the caller slot high-water mark on return.

---

## UpvalueDesc

Use:

```odin
UpvalueDesc :: struct {
	from_parent_local: bool,
	index:             int,
}
```

Meaning:

```text
from_parent_local = true:
  capture parent frame local slot `index`

from_parent_local = false:
  reuse parent function upvalue `index`
```

This lives on `Code`.

It is not an expression descriptor.

It is not runtime captured storage.

It is the recipe used by `LOAD_FUNCTION` when creating a `FunctionObject`.

---

## Upvalue

Use an index-based upvalue shape.

```odin
Upvalue :: struct {
	slot_index: int,
	closed:     Value,
}
```

Meaning:

```text
slot_index >= 0:
  open upvalue
  reads/writes VM.slots[slot_index]

slot_index < 0:
  closed upvalue
  reads/writes upvalue.closed
```

There is no `closed_initialized` because this plan does not use pending/uninitialized binding storage.

Do not store `location: ^Value`.

The Lua pointer model is useful prior art, but Rite can use a flatter VM-index model.

## Open upvalue read

```text
i = upvalue.slot_index
value = vm.slots[i]
```

## Closed upvalue read

```text
value = upvalue.closed
```

## Close upvalue

```text
i = upvalue.slot_index
upvalue.closed = vm.slots[i]
upvalue.slot_index = -1
```

---

## Open Upvalue Sharing

The VM needs:

```odin
open_upvalues: [dynamic]^Upvalue
```

Invariant:

```text
one live captured slot has at most one open Upvalue object
```

Reason:

```scheme
(def make-pair
  (fn ()
    (def x 0)

    [(fn ()
       (set x (+ x 1))
       x)

     (fn ()
       x)]))
```

Both closures must share the same captured `x`.

If each closure gets its own upvalue, mutation splits into two different values.

Required helper:

```text
find_or_create_open_upvalue(vm, absolute_slot):
  scan vm.open_upvalues for slot_index == absolute_slot
  if found, return it
  allocate Upvalue{slot_index = absolute_slot}
  append to vm.open_upvalues
  return it
```

This helper is earned because it owns the sharing invariant.

---

## VM

Conceptual target:

```odin
VM :: struct {
	slots:      [dynamic]Value,
	slot_count: int,

	frames:      [dynamic]CallFrame,
	frame_count: int,

	open_upvalues: [dynamic]^Upvalue,

	globals: [dynamic]GlobalBinding,
	symbols: [dynamic]^SymbolObject,

	error_string: string,
}
```

No `slot_initialized`.

No runtime binding object for every local.

No cell stack.

---

## Bytecode Additions

Add:

```text
LOAD_FUNCTION
GET_UPVALUE
SET_UPVALUE
CLOSE_UPVALUES
```

Existing `CALL` becomes able to call both native functions and Rite functions.

Existing `RETURN` becomes frame-aware.

Existing `MOVE` can continue to handle local slot reads and raw slot copies.

No `GET_LOCAL` is required for this plan.

No `STORE_LOCAL` is required for this plan.

No `BEGIN_DEF` is required for this plan.

## LOAD_FUNCTION

```text
child_code = frame.code.child_codes[child_code_index]

fn = new FunctionObject
fn.code = child_code
fn.upvalues = allocate len(child_code.upvalue_descs)

for each desc in child_code.upvalue_descs:
  if desc.from_parent_local:
    absolute_slot = frame.slot_base + desc.index
    fn.upvalues[i] = find_or_create_open_upvalue(vm, absolute_slot)
  else:
    fn.upvalues[i] = frame.upvalues[desc.index]

slots[dst] = fn
```

## GET_UPVALUE

```text
upvalue = frame.upvalues[upvalue_index]

if upvalue.slot_index >= 0:
  slots[dst] = vm.slots[upvalue.slot_index]
else:
  slots[dst] = upvalue.closed
```

## SET_UPVALUE

```text
upvalue = frame.upvalues[upvalue_index]

if upvalue.slot_index >= 0:
  vm.slots[upvalue.slot_index] = slots[src]
else:
  upvalue.closed = slots[src]
```

## CLOSE_UPVALUES

```text
absolute_start = frame.slot_base + start_slot

for each upvalue in vm.open_upvalues:
  if upvalue.slot_index >= absolute_start:
    i = upvalue.slot_index

    upvalue.closed = vm.slots[i]
    upvalue.slot_index = -1

    remove upvalue from vm.open_upvalues
```

Linearly scanning `open_upvalues` is the first implementation.

---

## Function Compilation

Rite currently reads source into Value trees, then compiles those trees.

Keep that.

No AST rewrite.

No token-stream lowering.

No ExprDesc system.

For:

```scheme
(fn (params...)
  body-form...)
```

Add:

```text
compile_fn(list, dst)
```

Steps:

```text
1. Validate form shape:
   - head is fn
   - params form is a list
   - each param is a symbol
   - no duplicate params

2. Create child CodeBuilder.

3. Install params as child locals:
   param0 -> slot 0
   param1 -> slot 1
   ...

4. Compile body forms using existing body rules.

5. Finish child Code.

6. Append child Code to parent.child_codes.

7. Emit LOAD_FUNCTION dst, child_code_index.
```

Function body compiles now.

Function body executes only when the function is called.

---

## Name Resolution

A name use resolves to:

```text
local slot
upvalue index
global binding
undefined
```

Resolution order:

```text
1. Search current builder locals.
2. If found, emit local access.
3. Otherwise capture through parent builders.
4. If captured, emit upvalue access.
5. Otherwise search globals.
6. Otherwise undefined name error.
```

Local access can keep using current slot-copy lowering.

Captured access uses `GET_UPVALUE` / `SET_UPVALUE`.

Global access keeps using existing global binding machinery.

## Capturing parent local

If current function needs a name from the immediate parent’s locals:

```text
current.upvalue_descs += {
  from_parent_local = true,
  index = parent_local_slot,
}

current.upvalue_symbols += symbol
```

The name compiles to:

```text
GET_UPVALUE dst, upvalue_index
```

`set` compiles to:

```text
SET_UPVALUE upvalue_index, src
```

## Capturing parent upvalue

If current function needs a name that the immediate parent already has as an upvalue:

```text
current.upvalue_descs += {
  from_parent_local = false,
  index = parent_upvalue_index,
}

current.upvalue_symbols += symbol
```

At runtime this reuses the parent upvalue pointer.

---

## Deep Closure Forwarding

Example:

```scheme
(fn ()
  (def x 1)

  (fn ()
    (fn ()
      x)))
```

The innermost function cannot directly capture the outer frame slot at runtime.

Its immediate parent is the middle function.

So the compiler makes the middle function capture/forward `x`.

Compile result:

```text
outer Code:
  local x in slot 0

middle Code:
  upvalue 0 = parent local slot 0

inner Code:
  upvalue 0 = parent upvalue 0
```

Runtime:

```text
outer creates middle:
  middle.upvalues[0] = find_or_create_open_upvalue(slot_of_x)

middle creates inner:
  inner.upvalues[0] = middle.upvalues[0]
```

All closures share the same Upvalue object.

---

## Scope Exit

Before a slot range dies, close open upvalues pointing into that range.

Required close points:

```text
function return
do scope exit
while body scope exit
any later lexical scope exit
```

`do` already saves:

```text
local_mark
slot_mark
outer_scope_start
```

Before restoring dead locals/slots, emit:

```text
CLOSE_UPVALUES slot_mark
```

Then restore:

```text
local_count = local_mark
next_slot = slot_mark
current_scope_local_start = outer_scope_start
```

For `while`, close body locals before jumping back to the loop head.

Reason:

```scheme
(def f
  (do
    (def x 10)
    (fn () x)))

(f) ; 10
```

`x` is out of lexical scope after `do`, but the closure must keep its binding storage alive.

---

## Globals

Keep globals for builtins and any existing host/global mechanism.

Root file defs are locals in root Code, not globals.

Global lookup remains fallback after lexical lookup fails.

Builtins remain global bindings.

A file/local `def` may shadow a builtin.

---

## Implementation Sequence

Do it in this order:

```text
1. Replace Active_Code/current singleton compile target with CodeBuilder state.
   Current builder owns bytecode/constants/locals/scope slots.

2. Extend Code with child_codes, param_count, and upvalue_descs.

3. Make file compile to root Code.

4. Add CallFrame and make run_code frame-based.

5. Add FunctionObject.

6. Add LOAD_FUNCTION for zero-capture functions.

7. Add CALL/RETURN for Rite FunctionObject.

8. Add compile_fn:
   validate params
   child builder
   params as locals
   body compile
   finish child Code
   emit LOAD_FUNCTION

9. Add Upvalue and VM.open_upvalues.

10. Add UpvalueDesc arrays to CodeBuilder and Code.

11. Extend name resolution to capture from parent builders.

12. Add GET_UPVALUE and SET_UPVALUE.

13. Add CLOSE_UPVALUES at function return and lexical scope exits.

14. Run proof tests.
```

No `slot_initialized` step.

No `GET_LOCAL` step.

No delayed ordinary `def` step.

---

## Proof Tests

## Plain function

```scheme
(def inc
  (fn (x)
    (+ x 1)))

(inc 10)
; 11
```

## Duplicate parameter error

```scheme
(fn (x x)
  x)
; error
```

## Wrong arity error

```scheme
(def add
  (fn (a b)
    (+ a b)))

(add 1)
; error
```

## Ordinary function-valued def is not self-recursive

```scheme
(def fact
  (fn (n)
    (fact (- n 1))))
```

If no outer `fact` exists, this is an undefined-name compile error.

That is expected.

## Manual self-recursion

```scheme
(def fact nil)

(set fact
  (fn (n)
    (if (= n 0)
      1
      (* n (fact (- n 1))))))

(fact 5)
; 120
```

## Closure read

```scheme
(def make-adder
  (fn (n)
    (fn (x)
      (+ x n))))

(def add10 (make-adder 10))

(add10 5)
; 15
```

## Separate closure instances

```scheme
(def add10 (make-adder 10))
(def add20 (make-adder 20))

(add10 5)
; 15

(add20 5)
; 25
```

## Closure mutation

```scheme
(def make-counter
  (fn ()
    (def n 0)

    (fn ()
      (set n (+ n 1))
      n)))

(def c (make-counter))

(c)
; 1

(c)
; 2
```

## Shared upvalue

```scheme
(def make-pair
  (fn ()
    (def x 0)

    [(fn ()
       (set x (+ x 1))
       x)

     (fn ()
       x)]))

(def pair (make-pair))
(def inc (pair 0))
(def get (pair 1))

(inc)
; 1

(get)
; 1
```

## Deep forwarding

```scheme
(def outer
  (fn ()
    (def x 10)

    (fn ()
      (fn ()
        x))))

(def middle (outer))
(def inner (middle))

(inner)
; 10
```

## Do-scope escaping closure

```scheme
(def f
  (do
    (def x 10)
    (fn () x)))

(f)
; 10
```

## Do-scope local does not escape as name

```scheme
(do
  (def x 10)
  x)
; 10

x
; error
```

## Top-level capture and mutation

```scheme
(def x 10)

(def f
  (fn ()
    x))

(f)
; 10

(set x 20)

(f)
; 20
```

---

## Delete These Older Ideas

Delete:

```text
BindingStorage enum
captured bool on LocalBinding
capture index on LocalBinding
runtime Binding object for every local
cell stack
public cell object
ExprDesc system
UninitializedValue union variant
ObjectKind.UNINITIALIZED
slot_initialized
closed_initialized
GET_LOCAL / STORE_LOCAL for initialization checks
BEGIN_DEF / INIT_LOCAL / pending ordinary def machinery
delayed ordinary def binding
location ^Value upvalue field
```

Use:

```text
LocalBinding = symbol + slot

ordinary def:
  ordered visibility
  RHS first
  publish name after RHS

self recursion:
  existing binding + set
  later named function def sugar

captured lifetime:
  Upvalue with slot_index while open
  Upvalue.closed after close

capture recipe:
  UpvalueDesc on Code
```

---

## Final Invariants

```text
Code is fixed executable data.

FunctionObject is runtime Code + resolved upvalues.

A local binding is a frame slot.

LocalBinding is compile-time symbol-to-slot metadata.

current_scope_local_start belongs to CodeBuilder/compiler state, not LocalBinding.

Ordinary def is ordered: RHS first, publish binding after RHS.

Ordinary def does not support self-recursion unless the name already resolves to an outer binding.

Manual self-recursion uses an existing binding plus set.

Named function definition later is recursive-binding sugar, not pure ordinary-def sugar.

A captured binding is represented by one shared Upvalue.

An open Upvalue indexes a live VM slot.

A closed Upvalue owns the captured Value.

One live captured slot has at most one open Upvalue.

UpvalueDesc tells LOAD_FUNCTION how to wire a child function’s upvalues from the immediate parent.

Deep closures work by intermediate functions forwarding upvalues.

Before a slot range dies, CLOSE_UPVALUES closes open upvalues pointing into that range.

Uncaptured locals remain ordinary slots.

Root file defs are root Code locals.

Modules and REPL are later policy layers, not part of first function bringup.
```
