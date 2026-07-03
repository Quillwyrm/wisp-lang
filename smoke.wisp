(def label "wisp smoke")
(def values [10 20 30])
(def output print)

(set (values 1)
  (+ (values 0) (values 2)))

(print label)
(print values)
(print (values 1))

(print (push values 50))
(print (pop values))
(print values)

(print
  (do
    (def x 5)
    (* x 2)))

(def previous 10)
(set previous [previous])
(print previous)

(print [nil true false 2.5])
(print (/ 20 2 5))
(print [(% -1 8) (= 1 1.0) (< 1 2) (>= 2 2)])
(print [(not nil) (not false) (not 0)])
(print [(len values) (len "wisp")])
(print [(type nil) (type true) (type 1) (type 1.0) (type "x") (type values) (type +)])
(assert true "not displayed")

(print [ + - / * ])

(def add +)
(print (add 400 20))

(print "hello" 420 60. [nil true])
(write "hello" 420 60. [nil true])
(write "write")
(print " works")

(output "done")

; variadic arithmetic 3+ args
(print (+ 1 2 3))
(print (- 10 2 3))
(print (* 2 3 4))

; variadic push
(print (push [1 2] 3 4 5))

; vector self-cycle display
(def cycle [])
(push cycle cycle)
(print cycle)

values

; error builtin (must be last — terminates execution)
(error "test-error")
