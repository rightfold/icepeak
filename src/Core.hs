module Core
(
  Core (coreClients), -- TODO: Expose only put for clients.
  EnqueueResult (..),
  Put (..),
  handlePut,
  processPuts,
  processUpdates,
  newCore,
  postQuit,
  enqueuePut,
  getCurrentValue,
  deleteValue
)
where

import Control.Concurrent.MVar (MVar, newMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TBQueue (TBQueue, newTBQueueIO, readTBQueue, writeTBQueue, isFullTBQueue)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, writeTVar, readTVar)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Prelude hiding (lookup)

import qualified Data.HashMap.Strict as HashMap

import WebsocketServer (ServerState)

import qualified WebsocketServer


type Path = [Text]
-- Put is a command to put a value at a given path.
data Put = Put Path Value deriving (Eq, Show)

-- The main value has been updated at the given path. The payload contains the
-- entire new value. (So not only the inner value at the updated path.)
data Updated = Updated Path Value deriving (Eq, Show)

data EnqueueResult = Enqueued | Dropped

data Core = Core
  { coreCurrentValue :: TVar Value
  , coreQueue :: TBQueue (Maybe Put)
  , coreUpdates :: TBQueue (Maybe Updated)
  , coreClients :: MVar ServerState
  }

newCore :: IO Core
newCore = do
  tvalue <- newTVarIO Null
  tqueue <- newTBQueueIO 128
  tupdates <- newTBQueueIO 128
  tclients <- newMVar WebsocketServer.newServerState
  pure (Core tvalue tqueue tupdates tclients)

-- Tell the put handler loop and the update handler loop to quit.
postQuit :: Core -> IO ()
postQuit core = atomically $ writeTBQueue (coreQueue core) Nothing


enqueuePut :: Put -> Core -> IO EnqueueResult
enqueuePut put core = atomically $ do
  isFull <- isFullTBQueue (coreQueue core)
  unless isFull $ writeTBQueue (coreQueue core) (Just put)
  pure $ if isFull then Dropped else Enqueued

deleteValue :: Path -> Core -> IO ()
deleteValue = error "TODO"

getCurrentValue :: Core -> Path -> IO (Maybe Value)
getCurrentValue core path =
  fmap (lookup path) $ atomically $ readTVar $ coreCurrentValue core

lookup :: Path -> Value -> Maybe Value
lookup path value = case path of
  [] -> Just value
  key : pathTail -> case value of
    Object dict -> HashMap.lookup key dict >>= lookup pathTail
    _notObject -> Nothing

-- Execute a "put" operation.
handlePut :: Put -> Value -> Value
handlePut (Put path newValue) value = case path of
  [] -> newValue
  key : pathTail ->
    let
      putInner = handlePut (Put pathTail newValue)
      newDict = case value of
        Object dict -> HashMap.alter (Just . putInner . fromMaybe Null) key dict
        _notObject  -> HashMap.singleton key (putInner Null)
    in
      Object newDict

-- Drain the queue of put operations and apply them. Once applied, publish the
-- new value as the current one, and also broadcast updates.
processPuts :: Core -> IO Value
processPuts core = go Null
  where
    go val = do
      maybePut <- atomically $ readTBQueue (coreQueue core)
      case maybePut of
        Just (Put path pvalue) -> do
          let newValue = handlePut (Put path pvalue) val
          atomically $ writeTVar (coreCurrentValue core) newValue
          atomically $ writeTBQueue (coreUpdates core) (Just $ Updated path newValue)
          go newValue
        Nothing -> do
          -- Stop the loop when we receive a Nothing. Tell the update loop to
          -- quit as well.
          atomically $ writeTBQueue (coreUpdates core) Nothing
          pure val

processUpdates :: Core -> IO ()
processUpdates core = go
  where
    go = do
      maybeUpdate <- atomically $ readTBQueue (coreUpdates core)
      case maybeUpdate of
        Just (Updated path value) -> do
          clients <- readMVar (coreClients core)
          WebsocketServer.broadcast path value clients
          putStrLn $ "Update at " ++ (show path) ++ ", new value: " ++ (show value)
          go
        -- Stop the loop when we receive a Nothing.
        Nothing -> pure ()
