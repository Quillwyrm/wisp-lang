Yeah, option 2 is fairly bounded **if you name the concept correctly**:

```text
binding target
```

Not “vector destructuring plus map destructuring.” The robust design is:

```text
A def/var target recursively introduces bindings from a value.
```

Once you say that, most of the semantics do fall out. But not all. There are maybe **six real decisions** you still need to specify.

Current Eld already has the relevant baseline: `def`/`var` targets are ordered, vector destructuring evaluates RHS once, new bindings become visible only after the destructuring definition evaluates, duplicate pattern symbols are errors, vector destructuring requires a vector with enough items, and extra items are ignored. Maps already have missing-key `nil`, non-`nil` keys only, and equality-based key lookup. 

## The good core model

I’d write the design as:

```text
target =
  symbol
  vector-pattern
  map-pattern

vector-pattern =
  [target...]

map-pattern =
  {literal-key target...}
```

That is the whole feature.

Examples:

```clojure
(def [x y] point)
```

```clojure
(def {:hp hp
      :name name}
  player)
```

```clojure
(def {:pos [x y]
      :stats {:hp hp
              :mp mp}}
  entity)
```

This is not “fancy.” It is just recursive binding targets.

## Semantics that naturally fall out

These are not really open questions if you accept the recursive-target model.

### 1. RHS evaluates once

```clojure
(def {:x x :y y} (make-point))
```

`make-point` runs once.

That follows from current `def`/`var` semantics. Destructuring is a target shape, not repeated expression sugar.

### 2. Targets are not expressions

Inside a target:

```clojure
{:pos [x y]}
```

the `{}` is not a map literal expression, and `[x y]` is not a vector literal expression. They are pattern syntax.

That already matches current vector destructuring:

```clojure
(def [x y] point)
```

`[x y]` there is not a vector value. Same principle.

### 3. `def` / `var` mutability applies to every introduced binding

```clojure
(def {:hp hp :name name} player)
```

creates immutable `hp` and `name`.

```clojure
(var {:hp hp :name name} player)
```

creates mutable `hp` and `name`.

No per-binding mutability inside the pattern. That would be extra policy with no current need.

### 4. Duplicate introduced names are errors across the whole target

This should error:

```clojure
(def {:hp x
      :mp x}
  stats)
```

This should also error:

```clojure
(def [x {:hp x}] data)
```

Because the target as a whole introduces `x` twice.

That is the robust rule:

```text
A binding target may not introduce the same symbol more than once.
```

### 5. Map lookup uses normal map semantics

This:

```clojure
(def {:hp hp} player)
```

means roughly:

```clojure
(def hp (key player :hp))
```

So missing key binds `nil`:

```clojure
(def {:missing x} {})
x
; nil
```

That falls directly out of existing `key` behavior.

### 6. Extra data is ignored

Vector already ignores extra vector items. Map destructuring should ignore extra map entries.

```clojure
(def {:hp hp} {:hp 100 :name "Rook"})
```

Only `hp` is bound.

That is what destructuring usually means: pull out what you asked for, ignore the rest.

## Semantics you do need to specify

These are the actual design-space points.

## 1. Are map keys literal-only?

Recommendation: **yes.**

Allowed:

```clojure
(def {:hp hp
      "name" name
      0 first
      true flag}
  m)
```

Disallowed:

```clojure
(def {some-key value} m)
(def {(compute-key) value} m)
```

Reason: a destructuring target should describe fixed data shape. Computed key lookup already exists:

```clojure
(def value (key m some-key))
```

So arbitrary key expressions inside patterns blur the boundary between target position and expression position.

Also: keys must be non-`nil`, because maps cannot use `nil` keys.

## 2. Are empty patterns allowed?

Current vector destructuring rejects empty vector patterns. I’d keep that principle.

Disallow:

```clojure
(def [] v)
(def {} m)
```

Reason: a `def`/`var` target should introduce at least one binding.

An empty pattern is a no-op definition target. It is not useful enough to earn special-case semantics.

So:

```text
Every binding target must introduce at least one symbol.
```

That means this is also invalid:

```clojure
(def {:x {}} m)
```

because the nested `{}` introduces nothing.

## 3. What happens when a nested branch is missing?

This is the most important semantic edge.

Example:

```clojure
(def {:pos [x y]} entity)
```

If `entity` is:

```clojure
{}
```

then `(key entity :pos)` is `nil`.

Now the inner pattern `[x y]` tries to destructure `nil` as a vector.

I’d make that an error:

```text
vector destructuring expects vector
```

So the rule is:

```text
Missing leaf binds nil.
Missing branch errors if you try to destructure through it.
```

Examples:

```clojure
(def {:hp hp} {})
hp
; nil
```

But:

```clojure
(def {:pos [x y]} {})
; error, because nil is not a vector
```

That is good. It lets scalar fields be optional by default, but nested structure must actually exist.

If the user wants optional nested structure, they write it explicitly:

```clojure
(def {:pos pos} entity)
(def pos (?? pos [0 0]))
(def [x y] pos)
```

That keeps optionality visible.

## 4. Do nested vector patterns keep the “must be long enough” rule?

Yes.

Current vector destructuring requires the vector to contain at least as many items as the pattern has symbols. Keep that for nested vector patterns too. 

```clojure
(def {:pos [x y]} {:pos [10]})
; error, expected at least 2 values
```

No nil-filling for vector destructuring. Function parameters nil-fill; vector destructuring does not. Keep those separate.

## 5. Duplicate map keys: by syntax or by value equality?

By **Eld equality**, same as maps.

This should error:

```clojure
(def {:hp hp
      "hp" hp2}
  m)
```

Because `:hp` is the string `"hp"` in Eld, and strings compare by contents. Colon strings explicitly produce string values in current Eld. 

This should also error:

```clojure
(def {1 a
      1.0 b}
  m)
```

if numeric equality says `1` equals `1.0`, which Eld currently does.

Rule:

```text
Duplicate literal keys in the same map pattern are errors according to Eld equality.
```

Duplicate keys in different nested map patterns are fine:

```clojure
(def {:left {:hp left-hp}
      :right {:hp right-hp}}
  pair)
```

## 6. What is the unpack order?

Specify source order, left-to-right.

For this:

```clojure
(def {:a a
      :b [b c]
      :d d}
  m)
```

Unpack proceeds:

```text
lookup :a
bind/extract a
lookup :b
destructure [b c]
lookup :d
bind d
```

There are not many visible side effects here because keys are literals, but order matters for diagnostics. If two things are wrong, the first one in source order should be the reported error.

## The robust final spec

I’d put it like this:

```text
A binding target may be a symbol, vector pattern, or map pattern.

A symbol target introduces one binding.

A vector pattern has the shape [target...].
It evaluates no expressions.
It requires the source value to be a vector.
The vector must contain at least as many items as the pattern has targets.
Items are destructured left-to-right from index 0.
Extra vector items are ignored.

A map pattern has the shape {literal-key target...}.
It evaluates no expressions.
It requires the source value to be a map.
Each key must be a literal non-nil value.
Keys are looked up left-to-right.
A missing key produces nil for that target.
Extra map entries are ignored.

Patterns may nest.

The whole target must introduce at least one symbol.
A target may not introduce the same symbol more than once.
A map pattern may not contain duplicate literal keys under Eld equality.

The RHS expression evaluates before any introduced binding is visible.
If destructuring fails at runtime, evaluation errors.
```

That is bounded and complete.

## Implementation shape implied by the design

Your current implementation has `compile_def_or_var` handling symbols, named functions, and flat vector patterns inline. The implementation record says the runtime already has `UNPACK_VECTOR` for vector destructuring and typed vector/map get/set bytecode for `idx`/`key` fast paths. 

If you go recursive, the honest internal concept is:

```text
binding target
```

So yes, this is one of the few cases where extracting target logic is earned.

Not because “helper good,” but because this invariant becomes real:

```text
Validate a recursive target.
Collect introduced symbols.
Compile unpacking from one source slot.
Publish all introduced bindings with the chosen mutability.
```

That is a real compiler concept, not cosmetic wrapping.

## My answer

The design mostly falls out once you commit to recursive binding targets.

The things you must explicitly specify are:

```text
literal-only map keys
empty patterns invalid
missing leaf -> nil
missing nested branch -> type error from inner pattern
duplicate keys by Eld equality
left-to-right unpack/error order
```

Everything else is inherited from existing Eld: ordered definitions, lexical visibility, `def`/`var` mutability, vector length checks, map missing-key `nil`, and runtime errors on wrong collection type.



---notes:

Yeah, I think this is a **real valuable construct**, not clever Lisp wizardry, as long as you keep the semantics you just agreed with.

This:

```clojure
(def {:pos [x y]
      :stats {:hp hp
              :mp mp}}
  entity)
```

is only arcane if the language hasn’t taught this idea:

```text
def target expr
target can be a symbol, vector pattern, or map pattern
patterns mirror data shape
```

Once that clicks, it is very readable. It says: “from `entity`, pull `:pos` as `[x y]`, and pull `:stats` as `{hp mp}`.”

That is not clever. It is compressed, but it is honest compression.

## The manual version

Manual equivalent:

```clojure
(def pos (key entity :pos))
(def [x y] pos)

(def stats (key entity :stats))
(def hp (key stats :hp))
(def mp (key stats :mp))
```

That is more Algol-brain obvious because every step is named. But it also introduces temporary names that may not matter:

```clojure
pos
stats
```

If you only need `x`, `y`, `hp`, and `mp`, then the destructuring version is actually more direct.

The manual version says **how to walk the object**.

The destructuring version says **what shape you expect**.

That is the value.

## Good usage cases

### 1. Entity/config/record-like maps

This is the obvious one for Eld.

```clojure
(def {:name name
      :pos [x y]
      :stats {:hp hp
              :speed speed}}
  entity)
```

In game/tool scripting, maps will naturally become little records/options/events. Destructuring makes that pleasant.

Manual version is noisy:

```clojure
(def name (key entity :name))
(def pos (key entity :pos))
(def [x y] pos)
(def stats (key entity :stats))
(def hp (key stats :hp))
(def speed (key stats :speed))
```

The destructuring version is better when those temps are just scaffolding.

### 2. Function argument unpacking later

Even if you only support `def`/`var` targets now, this becomes obviously useful if function params eventually accept targets:

```clojure
(def (draw-entity {:sprite sprite
                   :pos [x y]})
  (draw sprite x y))
```

That is nice. Not necessary now, but it shows the feature has a future that is not weird.

Without it:

```clojure
(def (draw-entity entity)
  (def sprite (key entity :sprite))
  (def pos (key entity :pos))
  (def [x y] pos)
  (draw sprite x y))
```

The latter is fine, but the destructured parameter version says the function’s expected input shape at the boundary.

### 3. Result objects

For APIs that return maps:

```clojure
(def {:ok ok
      :value value
      :err err}
  result)
```

Or nested:

```clojure
(def {:file {:path path
             :size size}
      :err err}
  result)
```

This is useful for tool scripts where APIs return structured data.

### 4. Event/message handling

```clojure
(def {:type type
      :mouse {:x x
              :y y
              :button button}}
  event)
```

Then:

```clojure
(case type
  :click (handle-click x y button)
  :move  (handle-move x y)
  nil)
```

This is a strong use case because events/messages are often nested maps.

### 5. Pulling fields from `pairs` / sequence data

If you eventually iterate maps as pair vectors:

```clojure
(def [k {:name name :hp hp}] pair)
```

That reads well: pair key plus destructured value.

## Where it becomes clever

This is good:

```clojure
(def {:pos [x y]
      :stats {:hp hp
              :mp mp}}
  entity)
```

This starts to get clever:

```clojure
(def {:a [{:b [x {:c y}]}]
      :d {:e {:f [g h i]}}}
  thing)
```

Not because the semantics are bad, but because the pattern becomes a puzzle. The reader has to simulate too much structure in their head.

So I’d think of the style rule as:

```text
Destructure one meaningful shape.
Do not turn a whole data traversal into punctuation soup.
```

One nested map/vector layer is great. Two can be fine. Three plus mixed nesting is usually a smell.

## The killer-feature part

The killer feature is not “less typing.”

The killer feature is that it makes the expected data shape local and visible:

```clojure
(def {:pos [x y]
      :stats {:hp hp
              :mp mp}}
  entity)
```

That is a little schema right at the binding site.

For a dynamic language, that is valuable. You do not have static record types telling you the shape. A destructuring target can serve as lightweight shape documentation.

That fits Eld’s intent: small eager Lisp, mutable collections, explicit `def`/`var`, direct scripting surface. The current ref already treats definitions as target/expression pairs and vector destructuring as a binding target, so recursive targets are an extension of an existing concept, not a random clever bolt-on. 

## Should Eld have it?

My honest take: **yes, this is a good Eld feature**.

Not because Lisps have destructuring. Because Eld has:

```text
maps as record-ish dynamic structures
vectors as small structured tuples
def/var target positions
explicit idx/key access
nil fallback
```

Recursive binding targets connect those pieces elegantly.

It would make code like this:

```clojure
(def pos (key entity :pos))
(def [x y] pos)
(def stats (key entity :stats))
(def hp (key stats :hp))
(def mp (key stats :mp))
```

become this:

```clojure
(def {:pos [x y]
      :stats {:hp hp
              :mp mp}}
  entity)
```

That is not hiding mutation, control flow, allocation, or dynamic dispatch. It is only hiding repetitive lookup/unpack mechanics.

That is a good abstraction.

## The edge of clever

I’d draw the line here:

Good:

```clojure
(def {:name name
      :pos [x y]}
  entity)
```

Good:

```clojure
(def {:left {:hp left-hp}
      :right {:hp right-hp}}
  combat)
```

Still good, but getting dense:

```clojure
(def {:entity {:id id
               :pos [x y]}
      :event {:type type}}
  message)
```

Probably too clever:

```clojure
(def [{:a [x {:b y}]}
      {:c {:d [e f]}}]
  data)
```

The feature is fine. Code style should discourage turning it into origami.

## Final vibe check

For Algol-brain, destructuring can feel like magic because assignment usually names one thing at a time.

For Eld, it is not magic if the rule is:

```text
A target can mirror the shape of the value it expects.
Symbols inside the target are the bindings created.
```

That is simple, powerful, and very Lisp-shaped in the good way.

So yes: I’d consider recursive destructuring a **legit Eld affordance**, not a niche trick. It is especially valuable because Eld is dynamic and map/vector-heavy.
