{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad (void)
import Control.Concurrent.Async
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TBQueue (readTBQueue)

import qualified System.Posix.Signals as Signals
import qualified Control.Concurrent.Async as Async

import Core (Core, coreLogRecords)

import qualified Core
import qualified HttpServer
import qualified Server
import qualified WebsocketServer

-- Instal SIGTERM and SIGINT handlers to do a graceful exit.
installHandlers :: Core -> Async () -> IO ()
installHandlers core serverThread =
  let
    handle = do
      Core.postQuit core
      Async.cancel serverThread
      Core.log "\nTermination sequence initiated ..." core
    handler = Signals.CatchOnce handle
    blockSignals = Nothing
    installHandler signal = Signals.installHandler signal handler blockSignals
  in do
    void $ installHandler Signals.sigTERM
    void $ installHandler Signals.sigINT

main :: IO ()
main = do
  core <- Core.newCore
  httpServer <- HttpServer.new core
  let wsServer = WebsocketServer.acceptConnection core
  pops <- Async.async $ Core.processOps core
  upds <- Async.async $ WebsocketServer.processUpdates core
  serv <- Async.async $ Server.runServer wsServer httpServer
  logger <- Async.async $ processLogRecords core
  installHandlers core serv
  Core.log "System online. ** robot sounds **" core
  void $ Async.wait pops
  void $ Async.wait upds
  void $ Async.wait serv
  void $ Async.wait logger


processLogRecords :: Core -> IO ()
processLogRecords core = go
  where
    go = do
      maybeLogRecord <- atomically $ readTBQueue (coreLogRecords core)
      case maybeLogRecord of
        Just logRecord -> do
          putStrLn $ show logRecord
          go
        -- stop the loop
        Nothing -> pure ()
