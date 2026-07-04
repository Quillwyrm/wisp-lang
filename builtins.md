; predicates
(nil? x)
(bool? x)
(num? x)
(int? x)
(float? x)
(str? x)
(vec? x)
(map? x)
(fn? x)
;(list? x) ;later when i have quote and meta stuff

; shared vec/map
(len x)
(copy x)  ; fresh shallow collection
(clear x) ; empties and returns the same collection

; vector
(push v value...)
(pop v)
(insert v i value)   ; mutates and returns v
(remove v i)         ; mutates and returns removed value
(slice v start count) ; fresh shallow vector

; map
(keys m)  ; fresh vector
(vals m)  ; fresh vector
(pairs m) ; fresh vector of [key value] vectors
(merge map map...) ; fresh map, later maps win

; higher-order, deferred until user functions
(each f coll)
(map f coll)
(filter pred coll)
(reduce f init coll)
