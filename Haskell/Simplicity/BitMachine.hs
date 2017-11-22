{-# LANGUAGE DeriveTraversable, GADTs #-}
module Simplicity.BitMachine
 ( MachineCodeF(..), MachineCode, MachineCodeK
 , end, crash, write, copy, skip, fwd, bwd, newFrame, moveFrame, dropFrame, (|||)
 , bump, nop
 , Cell
 , encode, decode
 , Interpreter, executeUsing
 ) where

import Control.Monad (unless)
import Control.Monad.Fail (MonadFail)
import Data.Functor.Fixedpoint (Fix(..), cata)

import Simplicity.Ty
import Simplicity.BitMachine.Ty

data MachineCodeF a = End
                    | Crash
                    | Write Bool a
                    | Copy Int a
                    | Skip Int a
                    | Fwd Int a
                    | Bwd Int a
                    | NewFrame Int a
                    | MoveFrame a
                    | DropFrame a
                    | Read a a
                    deriving (Functor, Show)

type MachineCode = Fix MachineCodeF
type MachineCodeK = MachineCode -> MachineCode

end :: MachineCode
end = Fix End

crash :: MachineCode
crash = Fix Crash

write :: Bool -> MachineCodeK
write b x = Fix (Write b x)

copy :: Int -> MachineCodeK
copy i x = Fix (Copy i x)

skip :: Int -> MachineCodeK
skip i x = Fix (Skip i x)

fwd :: Int -> MachineCodeK
fwd i x = Fix (Fwd i x)

bwd :: Int -> MachineCodeK
bwd i x = Fix (Bwd i x)

newFrame :: Int -> MachineCodeK
newFrame i x = Fix (NewFrame i x)

moveFrame :: MachineCodeK
moveFrame x = Fix (MoveFrame x)

dropFrame :: MachineCodeK
dropFrame x = Fix (DropFrame x)

(|||) :: MachineCodeK -> MachineCodeK -> MachineCodeK
x ||| y = \k -> Fix (Read (x k) (y k))

bump :: Int -> MachineCodeK -> MachineCodeK
bump i f = fwd i . f . bwd i

nop :: MachineCodeK
nop x = x

type Cell = Maybe Bool

safeSplitAt :: MonadFail m => Int -> [a] -> m ([a], [a])
safeSplitAt n l = do
  unless (0 <= n && n <= length l) (fail "safeSplitAt: index out of range")
  return (splitAt n l)

encode :: TyC a => a -> [Cell]
encode x = encodeR reify x []
 where
  encodeR :: TyReflect a -> a -> [Cell] -> [Cell]
  encodeR OneR () = id
  encodeR (SumR a b) (Left x) = ([Just False] ++) . (replicate (padLR a b) Nothing ++) . encodeR a x
  encodeR (SumR a b) (Right y) = ([Just True] ++) . (replicate (padRR a b) Nothing ++) . encodeR b y
  encodeR (ProdR a b) (x, y) = encodeR a x . encodeR b y

decode :: (MonadFail m, TyC a) => [Cell] -> m a
decode = decodeR reify
 where
  decodeR :: MonadFail m => TyReflect a -> [Cell] -> m a
  decodeR OneR [] = return ()
  decodeR (SumR a b) (Just v:l) = do
    (l0, l1) <- safeSplitAt (pad a b) l
    unless (all (==Nothing) l0) (fail "decodeR SumR: bad padding")
    if v then Right <$> decodeR b l1 else Left <$> decodeR a l1
   where
    pad = if v then padRR else padLR
  decodeR (ProdR a b) l = do
    (l0, l1) <- safeSplitAt (bitSizeR a) l
    (,) <$> decodeR a l0 <*> decodeR b l1
  decodeR _ _ = fail "decode: invalid encoding"

type Interpreter m = [Cell] -> Int -> m [Cell]

executeUsing :: (MonadFail m, TyC a, TyC b) => (arr a b -> Interpreter m) -> arr a b -> a -> m b
executeUsing interpreter program input = result
 where
  result = interpreter program (encode input) (bitSizeR (reifyProxy result)) >>= decode
