{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# OPTIONS_GHC -fplugin PlutusTx.Plugin #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:defer-errors #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:debug-context #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:profile-all #-}

{- | Executable for profiling. See note [Profiling instructions]-}

{- Note [Profiling instructions]
Add the program to be profiled in the "Programs to be profiled" section of this file.
Plugin options only work in the file the option is set,
so you have to define the programs in this file.
Add your program in @main@ by calling @writeLogToFile@.

Check your program's .timelog file and make sure has proper log in it.
You may get an error if the program's timed log is empty.

To get a flamegraph, you need to have flamegraph.pl from
https://github.com/brendangregg/FlameGraph/.
Input your program's .stack file to flamegraph.pl to get a flamegraph.
After that, you can use a browser to view it.
E.g.,
$ ~/FlameGraph/flamegraph.pl < plutus-tx-plugin/executables/profile/fib4.timelog.stacks > fib4.svg
$ firefox fib4.svg
 -}

module Main where
import           Common
import           PlcTestUtils              (ToUPlc (toUPlc), rethrow, runUPlcProfileExec)
import           Plugin.Basic.Spec

import qualified PlutusTx.Builtins         as Builtins
import           PlutusTx.Code             (CompiledCode)
import           PlutusTx.Plugin           (plc)

import qualified PlutusCore.Default        as PLC

import           Control.Lens.Combinators  (_2)
import           Control.Lens.Getter       (view)
import           Data.List                 (intercalate)
import           Data.Maybe                (fromJust)
import           Data.Proxy                (Proxy (Proxy))
import           Data.Text                 (Text)
import           Data.Time.Clock           (NominalDiffTime, UTCTime, diffUTCTime)
import           Prettyprinter.Internal    (pretty)
import           Prettyprinter.Render.Text (hPutDoc)
import           System.IO                 (IOMode (WriteMode), withFile)

data Stacks
  = MkStacks
  { -- | The variable name.
    varName           :: String,
    -- | The time when it starts to be evaluated.
    startTime         :: UTCTime,
    -- | The time spent on evaluating the functions it called.
    timeSpentCalledFn :: NominalDiffTime
  }
  deriving (Show)

-- | Write the time log of a program to a file in
-- the plutus-tx-plugin/executables/profile/ directory.
writeLogToFile ::
  ToUPlc a PLC.DefaultUni PLC.DefaultFun =>
  -- | Name of the file you want to save it as.
  FilePath ->
  -- | The program to be profiled.
  [a] ->
  IO ()
writeLogToFile fileName values = do
  let filePath = "plutus-tx-plugin/executables/profile/"<>fileName<>".timelog"
  log <- pretty . view _2 <$> (rethrow $ runUPlcProfileExec values)
  withFile
    filePath
    WriteMode
    (\h -> hPutDoc h log)
  processed <- processLog filePath
  writeFile (filePath<>".stacks") processed
  pure ()

processLog :: FilePath -> IO [Char]
processLog file = do
  content <- readFile file
  -- lEvents is in the form of [[t1,t2,t3,entering/exiting,var]]. Time is chopped to 3 parts.
  let lEvents =
        map
          -- @tail@ strips "[" in the first line and "," in the other lines,
          -- @words@ turns it to a list of [t1,t2,t3, enter/exit, var]
          (tail . words)
          -- turn to a list of events
          (lines content)
      lTime = map (unwords . take 3) lEvents
      -- list of enter/exit
      lEnterOrExit = map (!! 3) lEvents
      -- list of var
      lVar = map (!! 4) lEvents
      lTripleTimeVar = zip3 (lUTC lTime) lEnterOrExit lVar
      stacks = getStacks [] lTripleTimeVar
      fnsStacks = map (intercalate "; " . fst) stacks
      stacksFgFormat (hdf:tlf) (hdt:tlt)=
        hdf<>" "<>show hdt<>"\n":stacksFgFormat tlf tlt
      stacksFgFormat _ _ = []
  pure $
    concat $
      reverse $
        stacksFgFormat fnsStacks (map ((*1000000) . snd) stacks)

lUTC :: [String] -> [UTCTime]
lUTC = map (read :: String -> UTCTime)

getStacks ::
  -- | list of (var, its start time, the amount of time the functions it called spent)
  [Stacks] ->
  -- | the input log which is processed to a list of (UTCTime, entering/exiting, var name)
  [(UTCTime, String, String)] ->
  -- | a list of (fns it's in, var/function, the time spent on it)
  [([String],Double)]
getStacks curStack (hd:tl) =
  case hd of
    (time, "entering", var) ->
      getStacks
        (MkStacks{varName = var, startTime=time, timeSpentCalledFn = 0 :: NominalDiffTime}:curStack)
        tl
    (time, "exiting", var) ->
      let topOfStack = head curStack
          curTopVar = varName topOfStack
          curTopTime = startTime topOfStack
          curTimeSpent = timeSpentCalledFn topOfStack
      in
        if  curTopVar == var then
          let duration = diffUTCTime time curTopTime
              poppedStack = tail curStack
              updateTimeSpent (hd:tl) =
                hd {timeSpentCalledFn = timeSpentCalledFn hd + duration}:tl
              updateTimeSpent [] = []
              updatedStack = updateTimeSpent poppedStack
              fnsEntered = map varName updatedStack
          in
            -- time spent on this function is the total time spent
            -- minus the time spent on the function(s) it called.
            (fnsEntered <> [var], realToFrac (duration - curTimeSpent)::Double):getStacks updatedStack tl
        else error "getStacks: exiting a stack that is not on top of the stack."
    (_, badLog, _) -> error $
      "getStacks: log processed incorrectly. Expecting \"entering\" or \"exiting\" but got"
      <> show badLog
getStacks [] [] = []
getStacks stacks [] = error $
  "getStacks: stack " <> show stacks <> " isn't empty but the log is."

-------------------- Programs to be profiled -------------------

fact :: Integer -> Integer
fact n =
  if Builtins.equalsInteger n 0
    then 1
    else Builtins.multiplyInteger n (fact (Builtins.subtractInteger n 1))

factTest :: CompiledCode (Integer -> Integer)
factTest = plc (Proxy @"fact") fact

fib :: Integer -> Integer
fib n = if Builtins.equalsInteger n 0
          then 0
          else if Builtins.equalsInteger n 1
          then 1
          else Builtins.addInteger (fib(Builtins.subtractInteger n 1)) (fib(Builtins.subtractInteger n 2))

fibTest :: CompiledCode (Integer -> Integer)
-- not using case to avoid literal cases
fibTest = plc (Proxy @"fib") fib

addInt :: Integer -> Integer -> Integer
addInt x = Builtins.addInteger x

addIntTest :: CompiledCode (Integer -> Integer -> Integer)
addIntTest = plc (Proxy @"addInt") addInt

-- \x y -> let f z = z + 1 in f x + f y
letInFunTest :: CompiledCode (Integer -> Integer -> Integer)
letInFunTest =
  plc
    (Proxy @"letInFun")
    (\(x::Integer) (y::Integer)
      -> let f z = Builtins.addInteger z 1 in Builtins.addInteger (f x) (f y))

-- \x y z -> let f n = n + 1 in z * (f x + f y)
letInFunMoreArgTest :: CompiledCode (Integer -> Integer -> Integer -> Integer)
letInFunMoreArgTest =
  plc
    (Proxy @"letInFun")
    (\(x::Integer) (y::Integer) (z::Integer)
      -> let f n = Builtins.addInteger n 1 in
        Builtins.multiplyInteger z (Builtins.addInteger (f x) (f y)))

idTest :: CompiledCode Integer
idTest = plc (Proxy @"id") (id (1::Integer))

swap :: (a,b) -> (b,a)
swap (a,b) = (b,a)

swapTest :: CompiledCode (Integer,Bool)
swapTest = plc (Proxy @"swap") (swap (True,1))

main :: IO ()
main = do
  writeLogToFile "fib4" [toUPlc fibTest, toUPlc $ plc (Proxy @"4") (4::Integer)]
  writeLogToFile "fact4" [toUPlc factTest, toUPlc $ plc (Proxy @"4") (4::Integer)]
  writeLogToFile "addInt" [toUPlc addIntTest]
  writeLogToFile "addInt3" [toUPlc addIntTest, toUPlc  $ plc (Proxy @"3") (3::Integer)]
  writeLogToFile "letInFun" [toUPlc letInFunTest, toUPlc $ plc (Proxy @"1") (1::Integer), toUPlc $ plc (Proxy @"4") (4::Integer)]
  writeLogToFile "letInFunMoreArg" [toUPlc letInFunMoreArgTest, toUPlc $ plc (Proxy @"1") (1::Integer), toUPlc $ plc (Proxy @"4") (4::Integer), toUPlc $ plc (Proxy @"5") (5::Integer)]
  writeLogToFile "id" [toUPlc idTest]
  writeLogToFile "swap" [toUPlc swapTest]


