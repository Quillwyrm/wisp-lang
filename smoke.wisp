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

(print [ + - / * ])

(def add +)
(print (add 400 20))

(output "done")
values
