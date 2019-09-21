{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE TypeApplications #-}
module Spec.Contract(tests) where

import           Control.Monad                         (void)
import           Test.Tasty

import           Language.Plutus.Contract              as Con
import           Language.Plutus.Contract.Test
import           Language.Plutus.Contract.Util         (loopM)
import           Language.PlutusTx.Lattice
import           Ledger                                (Address)
import qualified Ledger                                as Ledger
import qualified Ledger.Ada                            as Ada
import           Prelude                               hiding (not)
import qualified Wallet.Emulator                       as EM

import qualified Language.Plutus.Contract.Effects.AwaitSlot as AwaitSlot

tests :: TestTree
tests = 
    let cp = checkPredicate @Schema in
    testGroup "contracts"
        [ cp "awaitSlot"
            (void $ awaitSlot 10)
            (waitingForSlot w1 10)
            $ pure ()

        , cp "selectEither"
            (void $ selectEither (awaitSlot 10) (awaitSlot 5))
            (waitingForSlot w1 5)
            $ pure ()

        , cp "until"
            (void $ awaitSlot 10 `Con.until` 5)
            (waitingForSlot w1 5)
            $ pure ()

        , cp "both"
            (void $ Con.both (awaitSlot 10) (awaitSlot 20))
            (waitingForSlot w1 10)
            $ pure ()

        , cp "both (2)"
            (void $ Con.both (awaitSlot 10) (awaitSlot 20))
            (waitingForSlot w1 20)
            $ addEvent w1 (AwaitSlot.event 10)

        , cp "fundsAtAddressGt"
            (void $ fundsAtAddressGt someAddress (Ada.adaValueOf 10))
            (interestingAddress w1 someAddress)
            $ pure ()

        , cp "watchAddressUntil"
            (void $ watchAddressUntil someAddress 5)
            (interestingAddress w1 someAddress /\ waitingForSlot w1 5)
            $ pure ()

        , cp "endpoint"
            (endpoint @"ep" @())
            (endpointAvailable @"ep" w1)
            $ pure ()

        , cp "call endpoint (1)"
            (void $ endpoint @"1" @Int >> endpoint @"2" @Int)
            (endpointAvailable @"1" w1)
            $ pure ()

        , cp "call endpoint (2)"
            (void $ endpoint @"1" @Int >> endpoint @"2" @Int)
            (endpointAvailable @"2" w1 /\ not (endpointAvailable @"1" w1))
            (callEndpoint @"1" @Int w1 1)

        , cp "call endpoint (3)"
            (void $ endpoint @"1" @Int >> endpoint @"2" @Int)
            (not (endpointAvailable @"2" w1) /\ not (endpointAvailable @"1" w1))
            (callEndpoint @"1" @Int w1 1 >> callEndpoint @"2" @Int w1 1)

        , cp "submit tx"
            (void $ writeTx mempty >> watchAddressUntil someAddress 20)
            (waitingForSlot w1 20 /\ interestingAddress w1 someAddress)
            (handleBlockchainEvents w1)

        , cp "select either"
            (let l = endpoint @"1" >> endpoint @"2"
                 r = endpoint @"3" >> endpoint @"4"
            in (void $ selectEither l r))
            (assertOutcome w1 ((==) Done) "left branch should finish")
            (callEndpoint @"3" w1 3 >> callEndpoint @"1" w1 1 >> callEndpoint @"2" w1 2)

        , cp "loopM"
            (void $ loopM (\_ -> Left <$> endpoint @"1" @Int) 0)
            (endpointAvailable @"1" w1)
            (callEndpoint @"1" @Int w1 1)

        , cp "collect until"
            (void $ collectUntil (+) 0 (endpoint @"1") 10)
            (endpointAvailable @"1" w1 /\ waitingForSlot w1 10)
            (callEndpoint @"1" @Int w1 1)
        ]

w1 :: EM.Wallet
w1 = EM.Wallet 1

someAddress :: Address
someAddress =
    -- this isn't the address of a valid validator script,
    -- but it doesn't matter because we only need the address,
    -- not the script
    Ledger.scriptAddress $
        Ledger.ValidatorScript $$(Ledger.compileScript [|| \(i :: Integer) -> i ||])

type Schema = 
    BlockchainActions 
        .\/ Endpoint "1" Int
        .\/ Endpoint "2" Int
        .\/ Endpoint "3" Int
        .\/ Endpoint "4" Int
        .\/ Endpoint "ep" ()