module Snapshot.PrimOpNumber01 where

import Prelude

foreign import a :: Number
foreign import b :: Number

test1 = a + b
test2 = a - b
test3 = a == b
test4 = a /= b
test5 = a < b
test6 = a > b
test7 = a <= b
test8 = a >= b
test9 = a * b
test10 = a / b
test11 = -a
