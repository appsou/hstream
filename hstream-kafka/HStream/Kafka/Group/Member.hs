{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

module HStream.Kafka.Group.Member where

import qualified Control.Concurrent     as C
import           Control.Monad          (join)
import qualified Data.ByteString        as BS
import           Data.Int               (Int32, Int64)
import qualified Data.IORef             as IO
import           Data.Maybe             (fromMaybe)
import qualified Data.Text              as T
import qualified Kafka.Protocol         as K
import qualified Kafka.Protocol.Service as K

data Member
  = Member
  { memberId           :: T.Text
  , rebalanceTimeoutMs :: IO.IORef Int32
  , sessionTimeoutMs   :: IO.IORef Int32
  , assignment         :: IO.IORef BS.ByteString
  , lastHeartbeat      :: IO.IORef Int64
  , heartbeatThread    :: IO.IORef (Maybe C.ThreadId)

  -- protocols
  , protocolType       :: T.Text
  , supportedProtocols :: IO.IORef [(T.Text, BS.ByteString)]

  -- client information
  , clientId           :: T.Text
  , clientHost         :: T.Text
  }

newMemberFromReq :: K.RequestContext -> K.JoinGroupRequestV0 -> T.Text -> [(T.Text, BS.ByteString)] -> IO Member
newMemberFromReq reqCtx req memberId supportedProtocols = do
  sessionTimeoutMs <- IO.newIORef req.sessionTimeoutMs
  rebalanceTimeoutMs <- IO.newIORef req.sessionTimeoutMs

  assignment <- IO.newIORef BS.empty

  lastHeartbeat <- IO.newIORef 0
  heartbeatThread <- IO.newIORef Nothing

  supportedProtocols' <- IO.newIORef supportedProtocols

  return $ Member {
      memberId=memberId
    , rebalanceTimeoutMs=rebalanceTimeoutMs
    , sessionTimeoutMs=sessionTimeoutMs

    , assignment=assignment

    , lastHeartbeat=lastHeartbeat
    , heartbeatThread=heartbeatThread

    , protocolType=req.protocolType
    , supportedProtocols=supportedProtocols'

    , clientId=fromMaybe "" (join reqCtx.clientId)
    , clientHost=T.pack reqCtx.clientHost
    }
