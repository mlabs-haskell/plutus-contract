--FIXME: remove interpretation
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -Wno-overlapping-patterns #-}
module Wallet.Emulator.MultiAgent where

import           Control.Lens                      (AReview, Getter, Lens',
                                                    Prism', anon, at, folded,
                                                    makeLenses, prism',
                                                    reversed, review, to, unto,
                                                    view, (&), (.~), (^.),
                                                    (^..))
import           Control.Monad                     (join)
import           Control.Monad.Freer               (Eff, Member, Members,
                                                    interpret, send, subsume,
                                                    type (~>))
import           Control.Monad.Freer.Error         (Error, throwError)
import           Control.Monad.Freer.Extras.Log    (LogMessage, LogMsg,
                                                    LogObserve,
                                                    handleObserveLog, mapLog)
import           Control.Monad.Freer.Extras.Modify (handleZoomedState, raiseEnd,
                                                    writeIntoState)
import           Control.Monad.Freer.State         (State, get)
import           Data.Aeson                        (FromJSON, ToJSON)
import           Data.Map                          (Map)
import qualified Data.Map                          as Map
import           Data.Maybe                        (fromMaybe)
import qualified Data.Text                         as T
import           Data.Text.Extras                  (tshow)
import           GHC.Generics                      (Generic)
import           Prettyprinter                     (Pretty (pretty), colon,
                                                    (<+>))

import           Ledger                            hiding (to, value)
import qualified Ledger.Ada                        as Ada
import qualified Ledger.AddressMap                 as AM
import qualified Ledger.Index                      as Index
import qualified Ledger.Value                      as Value
import qualified Plutus.ChainIndex.Emulator        as ChainIndex
import           Plutus.Contract.Error             (AssertionError (GenericAssertion))
import           Plutus.Trace.Emulator.Types       (ContractInstanceLog,
                                                    EmulatedWalletEffects,
                                                    EmulatedWalletEffects',
                                                    UserThreadMsg)
import qualified Plutus.Trace.Scheduler            as Scheduler
import qualified Wallet.API                        as WAPI
import qualified Wallet.Emulator.Chain             as Chain
import           Wallet.Emulator.LogMessages       (RequestHandlerLogMsg,
                                                    TxBalanceMsg)
import qualified Wallet.Emulator.NodeClient        as NC
import qualified Wallet.Emulator.Wallet            as Wallet
import           Wallet.Emulator.Wallet            (Wallet)

-- | Assertions which will be checked during execution of the emulator.
data Assertion
  = IsValidated CardanoTx -- ^ Assert that the given transaction is validated.
  | OwnFundsEqual Wallet Value -- ^ Assert that the funds belonging to a wallet's public-key address are equal to a value.

-- | An event with a timestamp measured in emulator time
--   (currently: 'Slot')
data EmulatorTimeEvent e =
    EmulatorTimeEvent
        { _eteEmulatorTime :: Slot
        , _eteEvent        :: e
        }
    deriving stock (Eq, Show, Generic, Functor, Foldable, Traversable)
    deriving anyclass (ToJSON, FromJSON)

makeLenses ''EmulatorTimeEvent

instance Pretty e => Pretty (EmulatorTimeEvent e) where
    pretty EmulatorTimeEvent{_eteEmulatorTime, _eteEvent} =
        pretty _eteEmulatorTime <> colon <+> pretty _eteEvent

emulatorTimeEvent :: Slot -> Prism' (EmulatorTimeEvent e) e
emulatorTimeEvent t = prism' (EmulatorTimeEvent t) (\case { EmulatorTimeEvent s e | s == t -> Just e; _ -> Nothing})

-- | Events produced by the blockchain emulator.
data EmulatorEvent' =
    ChainEvent Chain.ChainEvent
    | ClientEvent Wallet NC.NodeClientEvent
    | WalletEvent Wallet Wallet.WalletEvent
    | ChainIndexEvent Wallet ChainIndex.ChainIndexLog
    | SchedulerEvent Scheduler.SchedulerLog
    | InstanceEvent ContractInstanceLog
    | UserThreadEvent UserThreadMsg
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

instance Pretty EmulatorEvent' where
    pretty = \case
        ClientEvent w e     -> pretty w <> colon <+> pretty e
        ChainEvent e        -> pretty e
        WalletEvent w e     -> pretty w <> colon <+> pretty e
        ChainIndexEvent w e -> pretty w <> colon <+> pretty e
        SchedulerEvent e    -> pretty e
        InstanceEvent e     -> pretty e
        UserThreadEvent e   -> pretty e

type EmulatorEvent = EmulatorTimeEvent EmulatorEvent'

chainEvent :: Prism' EmulatorEvent' Chain.ChainEvent
chainEvent = prism' ChainEvent (\case { ChainEvent c -> Just c; _ -> Nothing })

walletClientEvent :: Wallet -> Prism' EmulatorEvent' NC.NodeClientEvent
walletClientEvent w = prism' (ClientEvent w) (\case { ClientEvent w' c | w == w' -> Just c; _ -> Nothing })

walletEvent :: Wallet -> Prism' EmulatorEvent' Wallet.WalletEvent
walletEvent w = prism' (WalletEvent w) (\case { WalletEvent w' c | w == w' -> Just c; _ -> Nothing })

walletEvent' :: Prism' EmulatorEvent' (Wallet, Wallet.WalletEvent)
walletEvent' = prism' (uncurry WalletEvent) (\case { WalletEvent w c -> Just (w, c); _ -> Nothing })

chainIndexEvent :: Wallet -> Prism' EmulatorEvent' ChainIndex.ChainIndexLog
chainIndexEvent w = prism' (ChainIndexEvent w) (\case { ChainIndexEvent w' c | w == w' -> Just c; _ -> Nothing })

schedulerEvent :: Prism' EmulatorEvent' Scheduler.SchedulerLog
schedulerEvent = prism' SchedulerEvent (\case { SchedulerEvent e -> Just e; _ -> Nothing })

instanceEvent :: Prism' EmulatorEvent' ContractInstanceLog
instanceEvent = prism' InstanceEvent (\case { InstanceEvent e -> Just e; _ -> Nothing })

userThreadEvent :: Prism' EmulatorEvent' UserThreadMsg
userThreadEvent = prism' UserThreadEvent (\case { UserThreadEvent e -> Just e ; _ -> Nothing })

type EmulatedWalletControlEffects =
        '[ NC.NodeClientControlEffect
         , ChainIndex.ChainIndexControlEffect
         , Wallet.SigningProcessControlEffect
         , LogObserve (LogMessage T.Text)
         , LogMsg T.Text
        ]

{- Note [Control effects]

Plutus contracts interact with the outside world through a number of different
effects. These effects are captured in 'EmulatedWalletEffects'. They are
supposed to be a realistic representation of the capabilities that contracts
will have in the real world, when the system is released.

In the tests we often want to simulate events that happened "outside of the
contract". For example: A new block is added to the chain, or a user takes the
transaction and emails it to another person to sign, before sending it to the
node. These kinds of events cannot be expressed in 'EmulatedWalletEffects',
because it would make the emulated wallet effects unrealistic - Plutus
contracts in the real world will not have the power to decide when a new block
gets added to the chain, or to control who adds their signature to a
transaction.

But in the emulated world of our unit tests we, the contract authors, would very
much like to have this power. That is why there is a second list of emulator
effects: 'EmulatedWalletControlEffects' are the of effects that only make sense
in the emulator, but not in the real world. With 'EmulatedWalletControlEffects'
we can control the blockchain and the lines of communication between the
emulated components.

By being clear about which of our (ie. the contract authors) actions
require the full power of 'EmulatedWalletControlEffects', we can be more
confident that our contracts will run in the real world, and not just in the
test environment. That is why there are two similar but different constructors
for 'MultiAgentEffect': 'WalletAction' is used for things that we will be able
to do in the real world, and 'WalletControlAction' is for everything else.

-}

-- | The type of actions in the emulator.
data MultiAgentEffect r where
    -- | A direct action performed by a wallet. Usually represents a "user action", as it is
    -- triggered externally.
    WalletAction :: Wallet -> Eff EmulatedWalletEffects r -> MultiAgentEffect r

data MultiAgentControlEffect r where
    -- | An action affecting the emulated parts of a wallet (only available in emulator - see note [Control effects].)
    WalletControlAction :: Wallet -> Eff EmulatedWalletControlEffects r -> MultiAgentControlEffect r
    -- | An assertion in the event stream, which can inspect the current state.
    Assertion :: Assertion -> MultiAgentControlEffect ()

-- | Run an action in the context of a wallet (ie. agent)
walletAction
    :: (Member MultiAgentEffect effs)
    => Wallet
    -> Eff EmulatedWalletEffects r
    -> Eff effs r
walletAction wallet act = send (WalletAction wallet act)

handleMultiAgentEffects ::
    forall effs.
    Member MultiAgentEffect effs
    => Wallet
    -> Eff (EmulatedWalletEffects' effs)
    ~> Eff effs
handleMultiAgentEffects wallet =
    interpret (raiseWallet @(LogMsg T.Text) wallet)
        . interpret (raiseWallet @(LogMsg TxBalanceMsg) wallet)
        . interpret (raiseWallet @(LogMsg RequestHandlerLogMsg) wallet)
        . interpret (raiseWallet @(LogObserve (LogMessage T.Text)) wallet)
        . interpret (raiseWallet @ChainIndex.ChainIndexQueryEffect wallet)
        . interpret (raiseWallet @WAPI.NodeClientEffect wallet)
        . interpret (raiseWallet @(Error WAPI.WalletAPIError) wallet)
        . interpret (raiseWallet @WAPI.WalletEffect wallet)

raiseWallet :: forall f effs.
    ( Member f EmulatedWalletEffects
    , Member MultiAgentEffect effs
    )
    => Wallet
    -> f
    ~> Eff effs
raiseWallet wllt = walletAction wllt . send

-- | Run a control action in the context of a wallet
walletControlAction
    :: (Member MultiAgentControlEffect effs)
    => Wallet
    -> Eff EmulatedWalletControlEffects r
    -> Eff effs r
walletControlAction wallet = send . WalletControlAction wallet

assertion :: (Member MultiAgentControlEffect effs) => Assertion -> Eff effs ()
assertion a = send (Assertion a)

-- | Issue an assertion that the funds for a given wallet have the given value.
assertOwnFundsEq :: (Member MultiAgentControlEffect effs) => Wallet -> Value -> Eff effs ()
assertOwnFundsEq wallet = assertion . OwnFundsEqual wallet

-- | Issue an assertion that the given transaction has been validated.
assertIsValidated :: (Member MultiAgentControlEffect effs) => CardanoTx -> Eff effs ()
assertIsValidated = assertion . IsValidated

-- | The state of the emulator itself.
data EmulatorState = EmulatorState {
    _chainState   :: Chain.ChainState, -- ^ Mockchain
    _walletStates :: Map Wallet Wallet.WalletState, -- ^ The state of each agent.
    _emulatorLog  :: [LogMessage EmulatorEvent] -- ^ The emulator log messages, with the newest last.
    } deriving (Show)

makeLenses ''EmulatorState

walletState :: Wallet -> Lens' EmulatorState Wallet.WalletState
walletState wallet = walletStates . at wallet . anon emptyState (const False) where
    emptyState = fromMaybe (error $ "walletState: not a known wallet: " <> show wallet) (Wallet.emptyWalletState wallet)

-- | Get the blockchain as a list of blocks, starting with the oldest (genesis)
--   block.
chainOldestFirst :: Lens' EmulatorState Blockchain
chainOldestFirst = chainState . Chain.chainNewestFirst . reversed

chainUtxo :: Getter EmulatorState AM.AddressMap
chainUtxo = chainState . Chain.chainNewestFirst . to AM.fromChain

-- | Get a map with the total value of each wallet's "own funds".
fundsDistribution :: EmulatorState -> Map Wallet Value
fundsDistribution st =
    let fullState = view chainUtxo st
        wallets = st ^.. walletStates . to Map.keys . folded
        walletFunds = flip fmap wallets $ \w ->
            (w, foldMap (txOutValue . snd) $ view (AM.fundsAt (Wallet.mockWalletAddress w)) fullState)
    in Map.fromList walletFunds

-- | Get the emulator log.
emLog :: EmulatorState -> [LogMessage EmulatorEvent]
emLog = view emulatorLog

emptyEmulatorState :: EmulatorState
emptyEmulatorState = EmulatorState {
    _chainState = Chain.emptyChainState,
    _walletStates = mempty,
    _emulatorLog = mempty
    }

-- | Initialise the emulator state with a blockchain.
emulatorState :: Blockchain -> EmulatorState
emulatorState bc = emptyEmulatorState
    & chainState . Chain.chainNewestFirst .~ bc
    & chainState . Chain.index .~ Index.initialise bc

-- | Initialise the emulator state with a pool of pending transactions.
emulatorStatePool :: Chain.TxPool -> EmulatorState
emulatorStatePool tp = emptyEmulatorState
    & chainState . Chain.txPool .~ tp

{- Note [Creating wallets with multiple outputs]

Every transaction needs a collateral input, which is a wallet output that gets spent
when the transaction fails to validate on chain (phase 2 validation). This output is required
to be an Ada-only output. To make sure we always have an Ada-only output available during emulation,
we create 10 Ada-only outputs per wallet here.
-}

-- | Initialise the emulator state with a single pending transaction that
--   creates the initial distribution of funds to public key addresses.
emulatorStateInitialDist :: Map PaymentPubKeyHash Value -> EmulatorState
emulatorStateInitialDist mp = emulatorStatePool [EmulatorTx tx] where
    tx = Tx
            { txInputs = mempty
            , txReferenceInputs = mempty
            , txCollateral = mempty
            , txOutputs = Map.toList mp >>= mkOutputs
            , txMint = foldMap snd $ Map.toList mp
            , txFee = mempty
            , txValidRange = WAPI.defaultSlotRange
            , txMintScripts = mempty
            , txSignatures = mempty
            , txRedeemers = mempty
            , txData = mempty
            }
    -- See [Creating wallets with multiple outputs]
    mkOutputs (key, vl) = mkOutput key <$> splitInto10 vl
    splitInto10 vl = replicate (fromIntegral count) (Ada.toValue (ada `div` count)) ++ remainder
        where
            ada = if Value.isAdaOnlyValue vl then Ada.fromValue vl else Ada.fromValue vl - minAdaTxOut
            -- Make sure we don't make the outputs too small
            count = min 10 $ ada `div` minAdaTxOut
            remainder = [ vl <> Ada.toValue (-ada) | not (Value.isAdaOnlyValue vl) ]
    mkOutput key vl = pubKeyHashTxOut vl (unPaymentPubKeyHash key)

type MultiAgentEffs =
    '[ State EmulatorState
     , LogMsg EmulatorEvent'
     , Error WAPI.WalletAPIError
     , Error ChainIndex.ChainIndexError
     , Error AssertionError
     , Chain.ChainEffect
     , Chain.ChainControlEffect
     ]

handleMultiAgentControl
    :: forall effs. Members MultiAgentEffs effs
    => Eff (MultiAgentControlEffect ': effs) ~> Eff effs
handleMultiAgentControl = interpret $ \case
    WalletControlAction wallet act -> do
        let
            p1 :: AReview EmulatorEvent' Wallet.WalletEvent
            p1 = walletEvent wallet
            p2 :: AReview EmulatorEvent' NC.NodeClientEvent
            p2 = walletClientEvent wallet
            p3 :: AReview EmulatorEvent' ChainIndex.ChainIndexLog
            p3 = chainIndexEvent wallet
            p4 :: AReview EmulatorEvent' T.Text
            p4 =  walletEvent wallet . Wallet._GenericLog
        act
            & raiseEnd
            & NC.handleNodeControl
            & interpret ChainIndex.handleControl
            & Wallet.handleSigningProcessControl
            & handleObserveLog
            & interpret (mapLog (review p4))
            & interpret (handleZoomedState (walletState wallet))
            & interpret (mapLog (review p1))
            & interpret (handleZoomedState (walletState wallet . Wallet.nodeClient))
            & interpret (mapLog (review p2))
            & interpret (handleZoomedState (walletState wallet . Wallet.chainIndexEmulatorState))
            & interpret (mapLog (review p3))
            & interpret (handleZoomedState (walletState wallet . Wallet.signingProcess))
            & interpret (writeIntoState emulatorLog)
    Assertion a -> assert a

handleMultiAgent
    :: forall effs. Members MultiAgentEffs effs
    => Eff (MultiAgentEffect ': effs) ~> Eff effs
handleMultiAgent = interpret $ \case
    -- TODO: catch, log, and rethrow wallet errors?
    WalletAction wallet act ->  do
        let
            p1 :: AReview EmulatorEvent' Wallet.WalletEvent
            p1 = walletEvent wallet
            p2 :: AReview EmulatorEvent' NC.NodeClientEvent
            p2 = walletClientEvent wallet
            p3 :: AReview EmulatorEvent' ChainIndex.ChainIndexLog
            p3 = chainIndexEvent wallet
            p4 :: AReview EmulatorEvent' T.Text
            p4 = walletEvent wallet . Wallet._GenericLog
            p5 :: AReview EmulatorEvent' RequestHandlerLogMsg
            p5 = walletEvent wallet . Wallet._RequestHandlerLog
            p6 :: AReview EmulatorEvent' TxBalanceMsg
            p6 = walletEvent wallet . Wallet._TxBalanceLog
        act
            & raiseEnd
            & interpret Wallet.handleWallet
            & subsume
            & NC.handleNodeClient
            & interpret ChainIndex.handleQuery
            & handleObserveLog
            & interpret (mapLog (review p5))
            & interpret (mapLog (review p6))
            & interpret (mapLog (review p4))
            & interpret (handleZoomedState (walletState wallet))
            & interpret (mapLog (review p1))
            & interpret (handleZoomedState (walletState wallet . Wallet.nodeClient))
            & interpret (mapLog (review p2))
            & interpret (handleZoomedState (walletState wallet . Wallet.chainIndexEmulatorState))
            & interpret (mapLog (review p3))
            & interpret (handleZoomedState (walletState wallet . Wallet.signingProcess))
            & interpret (writeIntoState emulatorLog)

-- | Issue an 'Assertion'.
assert :: (Members MultiAgentEffs effs) => Assertion -> Eff effs ()
assert (IsValidated txn)            = isValidated txn
assert (OwnFundsEqual wallet value) = ownFundsEqual wallet value

-- | Issue an assertion that the funds for a given wallet have the given value.
ownFundsEqual :: (Members MultiAgentEffs effs) => Wallet -> Value -> Eff effs ()
ownFundsEqual wallet value = do
    es <- get
    let total = foldMap (txOutValue . snd) $ es ^. chainUtxo . AM.fundsAt (Wallet.mockWalletAddress wallet)
    if value == total
    then pure ()
    else throwError $ GenericAssertion $ T.unwords ["Funds in wallet", tshow wallet, "were", tshow total, ". Expected:", tshow value]

-- | Issue an assertion that the given transaction has been validated.
isValidated :: (Members MultiAgentEffs effs) => CardanoTx -> Eff effs ()
isValidated txn = do
    emState <- get
    if notElem (Valid txn) (join $ emState ^. chainState . Chain.chainNewestFirst)
        then throwError $ GenericAssertion $ "Txn not validated: " <> T.pack (show txn)
        else pure ()

_singleton :: AReview [a] a
_singleton = unto return
