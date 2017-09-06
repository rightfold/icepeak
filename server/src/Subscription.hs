{-# LANGUAGE DeriveFunctor #-}

module Subscription
(
  SubscriptionTree (..),
  broadcast,
  empty,
  subscribe,
  unsubscribe,
  showTree,
)
where

import Control.Monad (void)
import Data.Aeson (Value)
import Data.HashMap.Strict (HashMap)
import Data.Hashable (Hashable)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)

import qualified Control.Concurrent.Async as Async
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text

import qualified Store

-- Keeps subscriptions in a tree data structure, so we can efficiently determine
-- which clients need to be notified for a given update.
data SubscriptionTree k v =
  SubscriptionTree (HashMap k v) (HashMap Text (SubscriptionTree k v))
  deriving (Eq, Functor, Show)

empty :: SubscriptionTree k v
empty = SubscriptionTree HashMap.empty HashMap.empty

isEmpty :: SubscriptionTree k v -> Bool
isEmpty (SubscriptionTree here inner) = HashMap.null here && HashMap.null inner

subscribe :: (Eq k, Hashable k) => [Text] -> k -> v -> SubscriptionTree k v -> SubscriptionTree k v
subscribe path subid subval (SubscriptionTree here inner) =
  case path of
    [] -> SubscriptionTree (HashMap.insert subid subval here) inner
    key : pathTail ->
      let
        subscribeInner = subscribe pathTail subid subval
        newInner = HashMap.alter (Just . subscribeInner . fromMaybe empty) key inner
      in
        SubscriptionTree here newInner

unsubscribe :: (Eq k, Hashable k) => [Text] -> k -> SubscriptionTree k v -> SubscriptionTree k v
unsubscribe path subid (SubscriptionTree here inner) =
  case path of
    [] -> SubscriptionTree (HashMap.delete subid here) inner
    key : pathTail ->
      let
        -- Remove the tail from the inner tree (if it exists). If that left the
        -- inner tree empty, remove the key altogether to keep the tree clean.
        justNotEmpty tree = if isEmpty tree then Nothing else Just tree
        unsubscribeInner = justNotEmpty . unsubscribe pathTail subid
        newInner = HashMap.update unsubscribeInner key inner
      in
        SubscriptionTree here newInner

-- Invoke f for all subscribers to the path. The subscribers get passed the
-- subvalue at the path that they are subscribed to.
broadcast :: (Value -> v -> IO ()) -> [Text] -> Value -> SubscriptionTree k v -> IO ()
broadcast f path value (SubscriptionTree here inner) =
  case path of
    [] -> do
      -- When the path is empty, all subscribers that are "here" or at a deeper
      -- level should receive a notification.
      -- We broadcast concurrently since all updates are independent of each other
      Async.forConcurrently_ here (f value)
      let broadcastInner key = broadcast f [] (Store.lookupOrNull [key] value)
      void $ HashMap.traverseWithKey broadcastInner inner

    key : pathTail -> case HashMap.lookup key inner of
      Nothing -> pure ()
      -- TODO: Extract the inner thing from the value as well; the client is not
      -- subscribed to the top-level thing after all.
      Just subs -> broadcast f pathTail (Store.lookupOrNull [key] value) subs

-- Show subscriptions, for debugging purposes.
showTree :: Show k => SubscriptionTree k v -> String
showTree tree =
  let
    withPrefix prefix (SubscriptionTree here inner) =
      let
        strHere :: String
        strHere = concatMap (\cid -> " * " <> (show cid) <> "\n") (HashMap.keys here)
        showInner iPrefix t = iPrefix <> "\n" <> withPrefix iPrefix t
        strInner :: String
        strInner = concat $ HashMap.mapWithKey (\key -> showInner (prefix <> "/" <> Text.unpack key)) inner
      in
        strHere <> strInner
  in
    "/\n" <> (withPrefix "" tree)