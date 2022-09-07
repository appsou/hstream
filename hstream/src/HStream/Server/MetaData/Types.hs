{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE TypeFamilies          #-}

module HStream.Server.MetaData.Types
  ( ViewSchema
  , RelatedStreams
  , PersistentQuery (..)
  , PersistentConnector (..)
  , QueryType (..)
  , ShardReader (..)
  , createInsertPersistentQuery
  , getQuerySink
  , getRelatedStreams
  , isStreamQuery
  , isViewQuery
  , getSubscriptionWithStream
  , setQueryStatus
  , groupbyStores
  , getQueryStatus
  ) where

import           Data.Aeson                    (FromJSON (..), ToJSON (..))
import           Data.Int                      (Int64)
import           GHC.Generics                  (Generic)
-- import           GHC.Stack                                 (HasCallStack)

import           Control.Concurrent
import qualified Data.HashMap.Strict           as HM
import           Data.IORef
import           Data.Maybe                    (fromJust)
import           Data.Text                     (Text)
import           Data.Time.Clock.System        (SystemTime (MkSystemTime))
import           Data.Word                     (Word32, Word64)
import           DiffFlow.Types
import           GHC.IO                        (unsafePerformIO)
import           Z.IO.Time                     (getSystemTime')
import           ZooKeeper.Types               (ZHandle)

import           HStream.MetaStore.Types       (HasPath (..), MetaHandle,
                                                MetaStore (..), MetaType,
                                                RHandle)
import qualified HStream.Server.ConnectorTypes as HCT
import           HStream.Server.HStreamApi     (Subscription (..))
import           HStream.Server.MetaData.Value
import           HStream.Server.Types          (ServerID, SubscriptionWrap (..))
import qualified HStream.Store                 as S
import           HStream.Utils                 (TaskStatus (..), cBytesToText)

--------------------------------------------------------------------------------

type ViewSchema     = [String]
type RelatedStreams = [Text]

data PersistentQuery = PersistentQuery
  { queryId          :: Text
  , queryBindedSql   :: Text
  , queryCreatedTime :: Int64
  , queryType        :: QueryType
  , queryStatus      :: TaskStatus
  , queryTimeCkp     :: Int64
  , queryHServer     :: ServerID
  } deriving (Generic, Show, FromJSON, ToJSON)

data PersistentConnector = PersistentConnector
  { connectorId          :: Text
  , connectorBoundSql    :: Text
  , connectorCreatedTime :: Int64
  , connectorStatus      :: TaskStatus
  , connectorTimeCkp     :: Int64
  , connectorHServer     :: ServerID
  } deriving (Generic, Show, FromJSON, ToJSON)

data QueryType
  = PlainQuery  RelatedStreams
  | StreamQuery RelatedStreams Text            -- ^ related streams and the stream it creates
  | ViewQuery   RelatedStreams Text ViewSchema -- ^ related streams and the view it creates
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data ShardReader = ShardReader
  { readerStreamName  :: Text
  , readerShardId     :: Word64
  , readerShardOffset :: S.LSN
  , readerReaderId    :: Text
  , readerReadTimeout :: Word32
  } deriving (Show, Generic, FromJSON, ToJSON)

instance HasPath ShardReader ZHandle where
  myRootPath = cBytesToText readerPath
instance HasPath SubscriptionWrap ZHandle where
  myRootPath = cBytesToText subscriptionsPath
instance HasPath PersistentQuery ZHandle where
  myRootPath = cBytesToText queriesPath

instance HasPath ShardReader RHandle where
  myRootPath = "readers"
instance HasPath SubscriptionWrap RHandle where
  myRootPath = "subscriptions"
instance HasPath PersistentQuery RHandle where
  myRootPath = "queries"

insertQuery :: MetaType PersistentQuery handle
  => Text -> Text -> Int64 -> QueryType -> ServerID -> handle -> IO ()
insertQuery queryId queryBindedSql queryCreatedTime queryType queryHServer h = do
  MkSystemTime queryTimeCkp _ <- getSystemTime'
  let queryStatus = Created
  insertMeta queryId PersistentQuery{..} h

getQueryStatus :: MetaType PersistentQuery handle => Text -> handle -> IO TaskStatus
getQueryStatus qid h = queryStatus . fromJust <$> getMeta qid h

setQueryStatus
  :: (MetaStore PersistentQuery handle, HasPath PersistentQuery handle) =>
  Text -> TaskStatus -> handle -> IO ()
setQueryStatus mid status = updateMetaWith mid (\(Just q) -> q { queryStatus = status }) Nothing

getSubscriptionWithStream :: MetaType SubscriptionWrap handle => handle -> Text -> IO [SubscriptionWrap]
getSubscriptionWithStream zk sName = do
  subs <- listMeta @SubscriptionWrap zk
  return $ filter ((== sName) . subscriptionStreamName . originSub) subs


--------------------------------------------------------------------------------

isViewQuery :: PersistentQuery -> Bool
isViewQuery PersistentQuery{..} =
  case queryType of
    ViewQuery{} -> True
    _           -> False

isStreamQuery :: PersistentQuery -> Bool
isStreamQuery PersistentQuery{..} =
  case queryType of
    StreamQuery{} -> True
    _             -> False

getRelatedStreams :: PersistentQuery -> RelatedStreams
getRelatedStreams PersistentQuery{..} =
  case queryType of
    (PlainQuery ss)    -> ss
    (StreamQuery ss _) -> ss
    (ViewQuery ss _ _) -> ss

getQuerySink :: PersistentQuery -> Text
getQuerySink PersistentQuery{..} =
  case queryType of
    PlainQuery{}      -> ""
    (StreamQuery _ s) -> s
    (ViewQuery _ s _) -> s

createInsertPersistentQuery :: Text -> Text -> QueryType -> ServerID -> MetaHandle -> IO (Text, Int64)
createInsertPersistentQuery qid queryText queryType queryHServer h = do
  MkSystemTime timestamp _ <- getSystemTime'
  insertQuery qid queryText timestamp queryType queryHServer h
  return (qid, timestamp)

groupbyStores :: IORef (HM.HashMap Text (MVar (DataChangeBatch HCT.Timestamp)))
groupbyStores = unsafePerformIO $ newIORef HM.empty
{-# NOINLINE groupbyStores #-}