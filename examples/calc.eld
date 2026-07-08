; calc - tiny infix arithmetic calculator.
;
; No operator precedence. Expressions evaluate left to right.
; Use parentheses for grouping.
; Tokens are split on whitespace, so write ( 1 + 2 ), not (1+2).
;
;   eld examples/calc.eld 1 + 2
;   eld examples/calc.eld "( 1 + 2 )" "*" 3

(import "os")
(import "str")


(def args (os/args))


(def (usage)
  (print "usage: eld examples/calc.eld EXPR")
  (print "ops: + - * / %")
  (print "grouping: ( expr )")
  (print "example: eld examples/calc.eld \"( 1 + 2 )\" \"*\" 3")
  (os/exit 1))

(def (tokens-from-args args)
  (def
    text   (str/join args " ")
    parts  (str/split text " ")
    tokens [])

  (var i 0)
  (while (< i (len parts))
    (def part (idx parts i))

    (if (!= part "")
      (push tokens part))

    (set i (+ i 1)))

  tokens)

(def (operator? token)
  (case token
    "+" true
    "-" true
    "*" true
    "/" true
    "%" true
    false))

(def (apply-op op left right)
  (case op
    "+" (+ left right)
    "-" (- left right)
    "*" (* left right)
    "/" (/ left right)
    "%" (% left right)
    (error (str "unknown operator: " op))))

(def (parse-expr tokens start)
  (def (parse-atom pos)
    (cond
      (>= pos (len tokens))
        [nil pos "expected number or ("]

      (= (idx tokens pos) "(")
        (do
          (def [value next err] (parse-expr tokens (+ pos 1)))

          (cond
            err
              [nil next err]

            (>= next (len tokens))
              [nil next "expected )"]

            (= (idx tokens next) ")")
              [value (+ next 1) nil]

            :else
              [nil next (str "expected ), got " (idx tokens next))]))

      (= (idx tokens pos) ")")
        [nil pos "unexpected )"]

      :else
        (do
          (def token (idx tokens pos))
          (def value (number token))

          (if (nil? value)
            [nil pos (str "expected number, got " token)]
            [value (+ pos 1) nil]))))

  (def [left pos err] (parse-atom start))

  (if err
    [nil pos err]
    (do
      (var
        result left
        i      pos
        error  nil)

      (while (and (nil? error)
                  (< i (len tokens))
                  (!= (idx tokens i) ")"))
        (def op (idx tokens i))

        (cond
          (operator? op)
            (do
              (def [right next err] (parse-atom (+ i 1)))

              (if err
                (set error err)
                (do
                  (set result (apply-op op result right))
                  (set i next))))

          :else
            (set error (str "expected operator, got " op))))

      [result i error])))


(if (= (len args) 0)
  (usage))

(def tokens (tokens-from-args args))

(if (= (len tokens) 0)
  (usage))

(def [value next err] (parse-expr tokens 0))

(cond
  err
    (do
      (print "calc error:" err)
      (os/exit 1))

  (< next (len tokens))
    (do
      (print "calc error: unexpected token:" (idx tokens next))
      (os/exit 1))

  :else
    (print value))
