{- | Plutus benchmarks based on some nofib examples. -}
module Main where

import           Shared                         (mkBenchMarks)

import           Criterion.Main

import           PlutusBenchmark.Common         (benchTermCek, getConfig)

import qualified PlutusBenchmark.NoFib.Clausify as Clausify
import qualified PlutusBenchmark.NoFib.Knights  as Knights
import qualified PlutusBenchmark.NoFib.Prime    as Prime
import qualified PlutusBenchmark.NoFib.Queens   as Queens

benchClausify :: Clausify.StaticFormula -> Benchmarkable
benchClausify f = benchTermCek $ Clausify.mkClausifyTerm f

benchPrime :: Prime.PrimeID -> Benchmarkable
benchPrime pid = benchTermCek $ Prime.mkPrimalityBenchTerm pid

benchQueens :: Integer -> Queens.Algorithm -> Benchmarkable
benchQueens sz alg = benchTermCek $ Queens.mkQueensTerm sz alg

benchKnights :: Integer -> Integer -> Benchmarkable
benchKnights depth sz = benchTermCek $ Knights.mkKnightsTerm depth sz

{- This runs all of the benchmarks, which will take a long time.
   To run an individual benmark, try, for example,

     stack bench plutus-benchmark:nofib --ba primetest/40digits

   or

     cabal bench plutus-benchmark:nofib --benchmark-options "primetest/40digits".

   Better results will be obtained with more repetitions of the benchmark.  Set
   the minimum time for the benchmarking process (in seconds) with the -L
   option. For example,

     stack bench plutus-benchmark:nofib --ba "primetest/40digits -L300"

   You can list the avaiable benchmarks with

     stack bench plutus-benchmark:nofib --ba --list

   or

     cabal bench plutus-benchmark:nofib --benchmark-options --list

-}

main :: IO ()
main = do
  let runners = (benchClausify, benchKnights, benchPrime, benchQueens)
  config <- getConfig 60.0  -- Run each benchmark for at least one minute.  Change this with -L or --timeout.
  defaultMainWith config $ mkBenchMarks runners
