(func $#relu_ternary_Int64  (param i64) (result i64)
  (i64.const 0)
  (get_local 0)
  (i64.lt_s)
  (if
    (then
      (get_local 0)
      (return)))
  (i64.const 0)
  (return))
