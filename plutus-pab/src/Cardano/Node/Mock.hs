{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Cardano.Node.Mock where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.MVar         (MVar, modifyMVar_, putMVar, takeMVar)
import           Control.Lens                    (over, set, unto, view)
import           Control.Monad                   (forever, unless, void)
import           Control.Monad.Freer             (Eff, Member, interpret, reinterpret, runM)
import           Control.Monad.Freer.Extras      (handleZoomedState)
import           Control.Monad.Freer.Log         (LogMessage (..), handleLogWriter, mapLog, renderLogMessages)
import           Control.Monad.Freer.Reader      (Reader)
import qualified Control.Monad.Freer.Reader      as Eff
import           Control.Monad.Freer.State       (State)
import qualified Control.Monad.Freer.State       as Eff
import qualified Control.Monad.Freer.Writer      as Eff
import           Control.Monad.IO.Class          (MonadIO, liftIO)
import           Data.Foldable                   (traverse_)
import           Data.List                       (genericDrop)
import           Data.Text                       (Text)
import           Data.Time.Units                 (Second, toMicroseconds)
import           Data.Time.Units.Extra           ()
import           Servant                         (NoContent (NoContent))

import           Ledger                          (Block, Slot (Slot), Tx)

import           Ledger.Tx                       (outputs)

import           Cardano.Node.Follower           (NodeFollowerEffect)
import           Cardano.Node.RandomTx
import           Cardano.Node.Types
import           Cardano.Protocol.ChainEffect    as CE
import           Cardano.Protocol.FollowerEffect as FE
import qualified Cardano.Protocol.Socket.Client  as Client
import qualified Cardano.Protocol.Socket.Server  as Server
import           Control.Monad.Freer.Extra.Log

import           Plutus.PAB.Arbitrary            ()

import           Cardano.BM.Data.Trace           (Trace)
import           Plutus.PAB.Monitoring           (runLogEffects)
import qualified Wallet.Emulator                 as EM
import           Wallet.Emulator.Chain           (ChainControlEffect, ChainEffect, ChainEvent, ChainState)
import qualified Wallet.Emulator.Chain           as Chain

healthcheck :: Monad m => m NoContent
healthcheck = pure NoContent

getCurrentSlot :: (Member (State ChainState) effs) => Eff effs Slot
getCurrentSlot = Eff.gets (view EM.currentSlot)


addBlock ::
    ( Member (LogMsg MockNodeLogMsg) effs
    , Member ChainControlEffect effs
    )
    => Eff effs ()
addBlock = do
    logInfo AddingSlot
    void Chain.processBlock

getBlocksSince ::
    ( Member ChainControlEffect effs
    , Member (State ChainState) effs
    )
    => Slot
    -> Eff effs [Block]
getBlocksSince (Slot slotNumber) = do
    void Chain.processBlock
    chainNewestFirst <- Eff.gets (view Chain.chainNewestFirst)
    pure $ genericDrop slotNumber $ reverse chainNewestFirst

consumeEventHistory :: MonadIO m => MVar AppState -> m [LogMessage ChainEvent]
consumeEventHistory stateVar =
    liftIO $ do
        oldState <- takeMVar stateVar
        let events = view eventHistory oldState
        let newState = set eventHistory mempty oldState
        putMVar stateVar newState
        pure events

addTx :: (Member (LogMsg MockNodeLogMsg) effs, Member ChainEffect effs) => Tx -> Eff effs NoContent
addTx tx = do
    logInfo $ AddingTx tx
    Chain.queueTx tx
    pure NoContent



type NodeServerEffects m
     = '[ GenRandomTx
        , LogMsg GenRandomTxMsg
        , NodeFollowerEffect
        , LogMsg NodeFollowerLogMsg
        , ChainControlEffect
        , ChainEffect
        , State NodeFollowerState
        , State ChainState
        , LogMsg ChainEvent
        , Reader Client.ClientHandler
        , Reader Server.ServerHandler
        , State AppState
        , LogMsg MockNodeLogMsg
        , LogMsg NodeServerMsg
        , LogMsg Text
        , m]

------------------------------------------------------------
runChainEffects ::
    Server.ServerHandler
 -> Client.ClientHandler
 -> MVar AppState
 -> Eff (NodeServerEffects IO) a
 -> IO ([LogMessage ChainEvent], a)
runChainEffects serverHandler clientHandler stateVar eff = do
    oldAppState <- liftIO $ takeMVar stateVar
    ((a, events), newState) <- liftIO
        $ runM
        $ runStderrLog
        $ interpret renderLogMessages
        $ interpret (mapLog NodeMockNodeMsg)
        $ Eff.runState oldAppState
        $ Eff.runReader serverHandler
        $ Eff.runReader clientHandler
        $ Eff.runWriter
        $ reinterpret (handleLogWriter @ChainEvent @[LogMessage ChainEvent] (unto return))
        $ interpret (handleZoomedState chainState)
        $ interpret (handleZoomedState followerState)
        $ CE.handleChain
        $ interpret Chain.handleControlChain
        $ interpret (mapLog NodeServerFollowerMsg)
        $ FE.handleNodeFollower
        $ interpret (mapLog NodeGenRandomTxMsg)
        $ runGenRandomTx
        $ do result <- eff
             void Chain.processBlock
             pure result
    liftIO $ putMVar stateVar newState
    pure (events, a)

processChainEffects ::
    Trace IO MockServerLogMsg
    -> Server.ServerHandler
    -> Client.ClientHandler
    -> MVar AppState
    -> Eff (NodeServerEffects IO) a
    -> IO a
processChainEffects trace serverHandler clientHandler stateVar eff = do
    (events, result) <- liftIO $ runChainEffects serverHandler clientHandler stateVar eff
    runLogEffects trace $ traverse_ (\(LogMessage _ chainEvent) -> logDebug $ ProcessingChainEvent chainEvent) events
    liftIO $
        modifyMVar_
            stateVar
            (\state -> pure $ over eventHistory (mappend events) state)
    pure result

-- | Calls 'addBlock' at the start of every slot, causing pending transactions
--   to be validated and added to the chain.
slotCoordinator ::
    Trace IO MockServerLogMsg
 ->  Second
 -> Server.ServerHandler
 -> Client.ClientHandler
 -> MVar AppState
 -> IO a
slotCoordinator trace slotLength serverHandler clientHandler stateVar =
    forever $ do
        void $ processChainEffects trace serverHandler clientHandler stateVar addBlock
        liftIO $ threadDelay $ fromIntegral $ toMicroseconds slotLength

-- | Generates a random transaction once in each 'mscRandomTxInterval' of the
--   config
transactionGenerator ::
  Trace IO MockServerLogMsg
 -> Second
 -> Server.ServerHandler
 -> Client.ClientHandler
 -> MVar AppState
 -> IO ()
transactionGenerator trace interval serverHandler clientHandler stateVar =
    forever $ do
        liftIO $ threadDelay $ fromIntegral $ toMicroseconds interval
        processChainEffects trace serverHandler clientHandler stateVar $ do
            tx' <- genRandomTx
            unless (null $ view outputs tx') (void $ addTx tx')

-- | Discards old blocks according to the 'BlockReaperConfig'. (avoids memory
--   leak)
blockReaper ::
  Trace IO MockServerLogMsg
 -> BlockReaperConfig
 -> Server.ServerHandler
 -> Client.ClientHandler
 -> MVar AppState
 -> IO ()
blockReaper tracer BlockReaperConfig {brcInterval, brcBlocksToKeep} serverHandler clientHandler stateVar =
    forever $ do
        void $
            processChainEffects
                tracer
                serverHandler
                clientHandler
                stateVar
                (Eff.modify (over Chain.chainNewestFirst (take brcBlocksToKeep)))
        liftIO $ threadDelay $ fromIntegral $ toMicroseconds brcInterval