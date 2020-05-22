{-# LANGUAGE OverloadedStrings #-}
module Main(main) where

import qualified Spec.Emulator
import qualified Spec.Rows
import qualified Spec.State
import           Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "plutus-contract" [
    Spec.Emulator.tests,
    Spec.State.tests,
    Spec.Rows.tests
    ]
