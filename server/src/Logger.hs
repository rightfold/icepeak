module Logger
(
  Logger,
  LogRecord,
  LogQueue,
  newLogger,
  postLog,
  postStop,
  processLogRecords
)
where

import Control.Monad (unless)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TBQueue (TBQueue, newTBQueue, readTBQueue, writeTBQueue, isFullTBQueue)
import Data.Text (Text)
import Prelude hiding (log)

import qualified Data.Text.IO as T

type LogRecord = Text
type LogQueue = TBQueue LogCommand

data Logger = Logger
  { loggerQueue :: LogQueue
  }

data LogCommand = LogRecord LogRecord | LogStop
  deriving (Eq, Ord, Show, Read)

newLogger :: Int -> IO Logger
newLogger queueSize = Logger <$> atomically (newTBQueue queueSize)

postLog :: Logger -> LogRecord -> IO ()
postLog logger record = atomically $ do
  isFull <- isFullTBQueue (loggerQueue logger)
  unless isFull $ writeTBQueue (loggerQueue logger) (LogRecord record)

postStop :: Logger -> IO ()
postStop logger = atomically $ writeTBQueue (loggerQueue logger) LogStop

processLogRecords :: Logger -> IO ()
processLogRecords logger = go
  where
    go = do
      cmd <- atomically $ readTBQueue (loggerQueue logger)
      case cmd of
        LogRecord logRecord -> do
          T.putStrLn logRecord
          go
        -- Stop the loop when we receive a Nothing.
        LogStop -> pure ()
