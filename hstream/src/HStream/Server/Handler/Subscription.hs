{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module HStream.Server.Handler.Subscription
  (
    createSubscriptionHandler,
    deleteSubscriptionHandler,
    listSubscriptionsHandler,
    checkSubscriptionExistHandler,
    streamingFetchHandler
  )
where

import           Control.Concurrent
import           Control.Monad                    (when, zipWithM)
import           Data.Function                    (on)
import           Data.Functor
import qualified Data.HashMap.Strict              as HM
import           Data.IORef                       (newIORef, readIORef,
                                                   writeIORef)
import qualified Data.List                        as L
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (catMaybes, fromJust)
import qualified Data.Text                        as T
import qualified Data.Text.Lazy                   as TL
import qualified Data.Vector                      as V
import           Data.Word                        (Word32, Word64)
import           HStream.Connector.HStore
import qualified HStream.Logger                   as Log
import           HStream.Server.Exception
import           HStream.Server.HStreamApi
import           HStream.Server.Handler.Common
import qualified HStream.Server.Persistence       as P
import qualified HStream.Store                    as S
import           HStream.ThirdParty.Protobuf      as PB
import           HStream.Utils
import           Network.GRPC.HighLevel.Generated
import           Proto3.Suite                     (Enumerated (..))
import           Z.Data.Vector                    (Bytes)
import           Z.Foreign                        (toByteString)
import           Z.IO.LowResTimer                 (registerLowResTimer)

--------------------------------------------------------------------------------

createSubscriptionHandler ::
  ServerContext ->
  ServerRequest 'Normal Subscription Subscription ->
  IO (ServerResponse 'Normal Subscription)
createSubscriptionHandler ServerContext {..} (ServerNormalRequest _metadata subscription@Subscription {..}) = defaultExceptionHandle $ do
  Log.debug $ "Receive createSubscription request: " <> Log.buildString (show subscription)

  let streamName = transToStreamName $ TL.toStrict subscriptionStreamName
  streamExists <- S.doesStreamExist scLDClient streamName
  if not streamExists
    then do
      Log.warning $
        "Try to create a subscription to a nonexistent stream"
          <> "Stream Name: "
          <> Log.buildString (show streamName)
      returnErrResp StatusInternal $ StatusDetails "stream not exist"
    else do
      logId <- S.getUnderlyingLogId scLDClient (transToStreamName . TL.toStrict $ subscriptionStreamName)
      offset <- convertOffsetToRecordId logId
      let newSub = subscription {subscriptionOffset = Just . SubscriptionOffset . Just . SubscriptionOffsetOffsetRecordOffset $ offset}
      P.storeSubscription newSub zkHandle
      returnResp subscription
  where
    convertOffsetToRecordId logId = do
      let SubscriptionOffset {..} = fromJust subscriptionOffset
          sOffset = fromJust subscriptionOffsetOffset
      case sOffset of
        SubscriptionOffsetOffsetSpecialOffset subOffset ->
          case subOffset of
            Enumerated (Right SubscriptionOffset_SpecialOffsetEARLIST) -> do
              return $ RecordId S.LSN_MIN 0
            Enumerated (Right SubscriptionOffset_SpecialOffsetLATEST) -> do
              startLSN <- (+ 1) <$> S.getTailLSN scLDClient logId
              return $ RecordId startLSN 0
            Enumerated _ -> error "Wrong SpecialOffset!"
        SubscriptionOffsetOffsetRecordOffset recordId -> return recordId

deleteSubscriptionHandler ::
  ServerContext ->
  ServerRequest 'Normal DeleteSubscriptionRequest Empty ->
  IO (ServerResponse 'Normal Empty)
deleteSubscriptionHandler ServerContext {..} (ServerNormalRequest _metadata req@DeleteSubscriptionRequest {..}) = defaultExceptionHandle $ do
  Log.debug $ "Receive deleteSubscription request: " <> Log.buildString (show req)

  modifyMVar_ subscribeRuntimeInfo $ \store -> do
    case HM.lookup deleteSubscriptionRequestSubscriptionId store of
      Just infoMVar -> do
        shouldDelete <-
          modifyMVar
            infoMVar
            ( \info@SubscribeRuntimeInfo {..} ->
                if HM.null sriStreamSends
                  then do
                    -- remove sub from zk
                    P.removeSubscription (TL.toStrict deleteSubscriptionRequestSubscriptionId) zkHandle
                    let newInfo = info {sriValid = False, sriStreamSends = HM.empty}
                    return (newInfo, True)
                  else return (info, False)
            )
        if shouldDelete
          then return $ HM.delete deleteSubscriptionRequestSubscriptionId store
          else return store
      Nothing -> do
        P.removeSubscription (TL.toStrict deleteSubscriptionRequestSubscriptionId) zkHandle
        return store

  returnResp Empty

checkSubscriptionExistHandler ::
  ServerContext ->
  ServerRequest 'Normal CheckSubscriptionExistRequest CheckSubscriptionExistResponse ->
  IO (ServerResponse 'Normal CheckSubscriptionExistResponse)
checkSubscriptionExistHandler ServerContext {..} (ServerNormalRequest _metadata req@CheckSubscriptionExistRequest {..}) = do
  Log.debug $ "Receive checkSubscriptionExistHandler request: " <> Log.buildString (show req)
  let sid = TL.toStrict checkSubscriptionExistRequestSubscriptionId
  res <- P.checkIfExist sid zkHandle
  returnResp . CheckSubscriptionExistResponse $ res

listSubscriptionsHandler ::
  ServerContext ->
  ServerRequest 'Normal ListSubscriptionsRequest ListSubscriptionsResponse ->
  IO (ServerResponse 'Normal ListSubscriptionsResponse)
listSubscriptionsHandler ServerContext {..} (ServerNormalRequest _metadata ListSubscriptionsRequest) = defaultExceptionHandle $ do
  Log.debug "Receive listSubscriptions request"
  res <- ListSubscriptionsResponse . V.fromList <$> P.listSubscriptions zkHandle
  Log.debug $ Log.buildString "Result of listSubscriptions: " <> Log.buildString (show res)
  returnResp res

streamingFetchHandler ::
  ServerContext ->
  ServerRequest 'BiDiStreaming StreamingFetchRequest StreamingFetchResponse ->
  IO (ServerResponse 'BiDiStreaming StreamingFetchResponse)
streamingFetchHandler ServerContext {..} (ServerBiDiRequest _ streamRecv streamSend) = do
  Log.debug "Receive streamingFetch request"

  consumerNameRef <- newIORef TL.empty
  subscriptionIdRef <- newIORef TL.empty
  handleRequest True consumerNameRef subscriptionIdRef
  where
    handleRequest isFirst consumerNameRef subscriptionIdRef = do
      streamRecv >>= \case
        Left (err :: grpcIOError) -> do
          Log.fatal . Log.buildString $ "streamRecv error: " <> show err

          cleanupStreamSend isFirst consumerNameRef subscriptionIdRef >>= \case
            Nothing -> return $ ServerBiDiResponse [] StatusInternal (StatusDetails "")
            Just errorMsg -> return $ ServerBiDiResponse [] StatusInternal (StatusDetails errorMsg)
        Right ma ->
          case ma of
            Just StreamingFetchRequest {..} -> do
              -- if it is the first fetch request from current client, need to do some extra check and add a new streamSender
              if isFirst
                then do
                  Log.debug "stream recive requst, do check in isFirst branch"

                  writeIORef consumerNameRef streamingFetchRequestConsumerName
                  writeIORef subscriptionIdRef streamingFetchRequestSubscriptionId

                  mRes <-
                    modifyMVar
                      subscribeRuntimeInfo
                      ( \store -> do
                          case HM.lookup streamingFetchRequestSubscriptionId store of
                            Just infoMVar -> do
                              modifyMVar_
                                infoMVar
                                ( \info@SubscribeRuntimeInfo {..} -> do
                                    -- bind a new sender to current client
                                    let newSends = HM.insert streamingFetchRequestConsumerName streamSend sriStreamSends
                                    if V.null sriSignals
                                      then return $ info {sriStreamSends = newSends}
                                      else do
                                        -- wake up all threads waiting for a new
                                        -- consumer to join
                                        V.forM_ sriSignals $ flip putMVar ()
                                        return $ info {sriStreamSends = newSends, sriSignals = V.empty}
                                )
                              return (store, Nothing)
                            Nothing -> do
                              mSub <- P.getSubscription (TL.toStrict streamingFetchRequestSubscriptionId) zkHandle
                              case mSub of
                                Nothing -> return (store, Just "Subscription has been removed")
                                Just sub@Subscription {..} -> do
                                  let startRecordId = getStartRecordId sub
                                  newInfoMVar <-
                                    initSubscribe
                                      scLDClient
                                      streamingFetchRequestSubscriptionId
                                      subscriptionStreamName
                                      streamingFetchRequestConsumerName
                                      startRecordId
                                      streamSend
                                      subscriptionAckTimeoutSeconds
                                  Log.info $ "Subscription " <> Log.buildString (show subscriptionSubscriptionId) <> " inits done."
                                  let newStore = HM.insert streamingFetchRequestSubscriptionId newInfoMVar store
                                  return (newStore, Nothing)
                      )
                  case mRes of
                    Just errorMsg ->
                      return $ ServerBiDiResponse [] StatusInternal (StatusDetails errorMsg)
                    Nothing ->
                      handleAcks
                        streamingFetchRequestSubscriptionId
                        streamingFetchRequestAckIds
                        consumerNameRef
                        subscriptionIdRef
                else
                  handleAcks
                    streamingFetchRequestSubscriptionId
                    streamingFetchRequestAckIds
                    consumerNameRef
                    subscriptionIdRef
            Nothing -> do
              -- This means that the consumer finished sending acks actively.
              Log.info "consumer closed"
              cleanupStreamSend isFirst consumerNameRef subscriptionIdRef >>= \case
                Nothing -> return $ ServerBiDiResponse [] StatusInternal (StatusDetails "")
                Just errorMsg -> return $ ServerBiDiResponse [] StatusInternal (StatusDetails errorMsg)

    handleAcks subId acks consumerNameRef subscriptionIdRef =
      if V.null acks
        then handleRequest False consumerNameRef subscriptionIdRef
        else do
          withMVar
            subscribeRuntimeInfo
            ( return . HM.lookup subId
            )
            >>= \case
              Just infoMVar -> do
                doAck scLDClient infoMVar acks
                handleRequest False consumerNameRef subscriptionIdRef
              Nothing ->
                return $ ServerBiDiResponse [] StatusInternal (StatusDetails "Subscription has been removed")

    -- We should cleanup according streamSend before returning ServerBiDiResponse.
    cleanupStreamSend isFirst consumerNameRef subscriptionIdRef = do
      if isFirst
        then return Nothing
        else
          withMVar
            subscribeRuntimeInfo
            ( \store -> do
                subscriptionId <- readIORef subscriptionIdRef
                consumerName <- readIORef consumerNameRef
                case HM.lookup subscriptionId store of
                  Nothing -> return $ Just "Subscription has been removed"
                  Just infoMVar -> do
                    modifyMVar_
                      infoMVar
                      ( \info@SubscribeRuntimeInfo {..} -> do
                          if sriValid
                            then do
                              let newStreamSends = HM.delete consumerName sriStreamSends
                              return $ info {sriStreamSends = newStreamSends}
                            else return info
                      )
                    return Nothing
            )

    initSubscribe ldclient subscriptionId streamName consumerName startRecordId sSend ackTimeout = do
      -- create a ldCkpReader for reading new records
      ldCkpReader <-
        S.newLDRsmCkpReader
          ldclient
          (textToCBytes $ TL.toStrict subscriptionId)
          S.checkpointStoreLogID
          5000
          1
          Nothing
          10
      -- seek ldCkpReader to start offset
      logId <- S.getUnderlyingLogId ldclient (transToStreamName (TL.toStrict streamName))
      let startLSN = recordIdBatchId startRecordId
      S.ckpReaderStartReading ldCkpReader logId startLSN S.LSN_MAX
      -- set ldCkpReader timeout to 0
      _ <- S.ckpReaderSetTimeout ldCkpReader 0
      Log.debug $ Log.buildString "created a ldCkpReader for subscription {" <> Log.buildLazyText subscriptionId <> "} with startLSN {" <> Log.buildInt startLSN <> "}"

      -- create a ldReader for rereading unacked records
      ldReader <- S.newLDReader ldclient 1 Nothing
      Log.debug $ Log.buildString "created a ldReader for subscription {" <> Log.buildLazyText subscriptionId <> "}"

      -- init SubscribeRuntimeInfo
      let info =
            SubscribeRuntimeInfo
              { sriStreamName = TL.toStrict streamName,
                sriLogId = logId,
                sriAckTimeoutSeconds = ackTimeout,
                sriLdCkpReader = ldCkpReader,
                sriLdReader = Just ldReader,
                sriWindowLowerBound = startRecordId,
                sriWindowUpperBound = maxBound,
                sriAckedRanges = Map.empty,
                sriBatchNumMap = Map.empty,
                sriStreamSends = HM.singleton consumerName sSend,
                sriValid = True,
                sriSignals = V.empty
              }

      infoMVar <- newMVar info
      -- create a task for reading and dispatching records periodicly
      _ <- forkIO $ readAndDispatchRecords infoMVar
      return infoMVar

    -- read records from logdevice and dispatch them to consumers
    readAndDispatchRecords runtimeInfoMVar = do
      Log.debug $ Log.buildString "enter readAndDispatchRecords"

      modifyMVar
        runtimeInfoMVar
        ( \info@SubscribeRuntimeInfo {..} ->
            if sriValid
              then do
                if not (HM.null sriStreamSends)
                  then do
                    void $ registerLowResTimer 10 $ void . forkIO $ readAndDispatchRecords runtimeInfoMVar
                    S.ckpReaderReadAllowGap sriLdCkpReader 1000 >>= \case
                      Left gap@S.GapRecord {..} -> do
                        -- insert gap range to ackedRanges
                        let gapLoRecordId = RecordId gapLoLSN minBound
                            gapHiRecordId = RecordId gapHiLSN maxBound
                            newRanges = Map.insert gapLoRecordId (RecordIdRange gapLoRecordId gapHiRecordId) sriAckedRanges
                            newInfo = info {sriAckedRanges = newRanges}
                        Log.debug . Log.buildString $ "reader meet a gapRecord for stream " <> show sriStreamName <> ", the gap is " <> show gap
                        Log.debug . Log.buildString $ "update ackedRanges to " <> show newRanges
                        return (newInfo, Nothing)
                      Right dataRecords -> do
                        if null dataRecords
                          then do
                            Log.debug . Log.buildString $ "reader read empty dataRecords from stream " <> show sriStreamName
                            return (info, Nothing)
                          else do
                            Log.debug . Log.buildString $ "reader read " <> show (length dataRecords) <> " records"
                            let groups = L.groupBy ((==) `on` S.recordLSN) dataRecords
                                groupNums = map (\group -> (S.recordLSN $ head group, (fromIntegral $ length group) :: Word32)) groups
                                lastBatch = last groups
                                maxRecordId = RecordId (S.recordLSN $ head lastBatch) (fromIntegral $ length lastBatch - 1)
                                -- update window upper bound and batchNumMap
                                newBatchNumMap = Map.union sriBatchNumMap (Map.fromList groupNums)
                                receivedRecords = fetchResult groups

                            newStreamSends <- dispatchRecords receivedRecords sriStreamSends
                            let receivedRecordIds = V.map (fromJust . receivedRecordRecordId) receivedRecords
                                newInfo =
                                  info
                                    { sriBatchNumMap = newBatchNumMap,
                                      sriWindowUpperBound = maxRecordId,
                                      sriStreamSends = newStreamSends
                                    }
                            -- register task for resending timeout records
                            void $
                              registerLowResTimer
                                (fromIntegral sriAckTimeoutSeconds * 10)
                                ( void $ forkIO $ tryResendTimeoutRecords receivedRecordIds sriLogId runtimeInfoMVar
                                )
                            return (newInfo, Nothing)
                  else do
                    signal <- newEmptyMVar
                    return (info {sriSignals = V.cons signal sriSignals}, Just signal)
              else return (info, Nothing)
        )
        >>= \case
          Nothing -> return ()
          Just signal -> do
            void $ takeMVar signal
            readAndDispatchRecords runtimeInfoMVar

    filterUnackedRecordIds recordIds ackedRanges windowLowerBound =
      flip V.filter recordIds $ \recordId ->
        (recordId >= windowLowerBound)
          && case Map.lookupLE recordId ackedRanges of
            Nothing                               -> True
            Just (_, RecordIdRange _ endRecordId) -> recordId > endRecordId

    tryResendTimeoutRecords recordIds logId infoMVar = do
      Log.debug "enter tryResendTimeoutRecords"
      modifyMVar
        infoMVar
        ( \info@SubscribeRuntimeInfo {..} -> do
            if sriValid
              then do
                let unackedRecordIds = filterUnackedRecordIds recordIds sriAckedRanges sriWindowLowerBound
                if V.null unackedRecordIds
                  then return (info, Nothing)
                  else do
                    Log.info $ Log.buildInt (V.length unackedRecordIds) <> " records need to be resend"
                    doResend info unackedRecordIds
              else return (info, Nothing)
        )
        >>= \case
          Nothing -> return ()
          Just signal -> do
            void $ takeMVar signal
            tryResendTimeoutRecords recordIds logId infoMVar
      where
        registerResend records timeout =
          registerLowResTimer timeout $
            void . forkIO $ tryResendTimeoutRecords records logId infoMVar

        -- TODO: maybe we can read these unacked records concurrently
        doResend info@SubscribeRuntimeInfo {..} unackedRecordIds = do
          let consumerNum = HM.size sriStreamSends
          if consumerNum == 0
            then do
              Log.debug . Log.buildString $ "no consumer to resend unacked msg, will block"
              signal <- newEmptyMVar
              return (info {sriSignals = V.cons signal sriSignals}, Just signal)
            else do
              streamSendValidRef <- newIORef $ V.replicate consumerNum True
              let senders = HM.toList sriStreamSends
              V.iforM_ unackedRecordIds $ \i RecordId {..} -> do
                S.readerStartReading (fromJust sriLdReader) logId recordIdBatchId recordIdBatchId
                let batchSize = fromJust $ Map.lookup recordIdBatchId sriBatchNumMap
                dataRecords <- S.readerRead (fromJust sriLdReader) (fromIntegral batchSize)
                if null dataRecords
                  then do
                    -- TODO: retry or error
                    Log.fatal $ "can not read log " <> Log.buildString (show logId) <> " at " <> Log.buildString (show recordIdBatchId)
                  else do
                    let ci = i `mod` consumerNum
                    streamSendValid <- readIORef streamSendValidRef
                    when (streamSendValid V.! ci) $ do
                      let cs = snd $ senders L.!! ci
                          rr = mkReceivedRecord (fromIntegral recordIdBatchIndex) (dataRecords !! fromIntegral recordIdBatchIndex)
                      cs (StreamingFetchResponse $ V.singleton rr) >>= \case
                        Left grpcIOError -> do
                          -- TODO: maybe we can cache these records so that the next round resend can reuse it without read from logdevice
                          Log.fatal $ "streamSend error:" <> Log.buildString (show grpcIOError)
                          let newStreamSendValid = V.update streamSendValid (V.singleton (ci, False))
                          writeIORef streamSendValidRef newStreamSendValid
                        Right _ -> return ()

              void $ registerResend unackedRecordIds (fromIntegral sriAckTimeoutSeconds * 10)

              valids <- readIORef streamSendValidRef
              let newStreamSends = map snd $ L.filter (\(i, _) -> valids V.! i) $ zip [0 ..] senders
              return (info {sriStreamSends = HM.fromList newStreamSends}, Nothing)

--------------------------------------------------------------------------------
--

fetchResult :: [[S.DataRecord Bytes]] -> V.Vector ReceivedRecord
fetchResult groups = V.fromList $ concatMap (zipWith mkReceivedRecord [0 ..]) groups

mkReceivedRecord :: Int -> S.DataRecord Bytes -> ReceivedRecord
mkReceivedRecord index record =
  let recordId = RecordId (S.recordLSN record) (fromIntegral index)
   in ReceivedRecord (Just recordId) (toByteString . S.recordPayload $ record)

commitCheckPoint :: S.LDClient -> S.LDSyncCkpReader -> T.Text -> RecordId -> IO ()
commitCheckPoint client reader streamName RecordId {..} = do
  logId <- S.getUnderlyingLogId client $ transToStreamName streamName
  S.writeCheckpoints reader (Map.singleton logId recordIdBatchId)

dispatchRecords ::
  Show a =>
  V.Vector ReceivedRecord ->
  HM.HashMap ConsumerName (StreamingFetchResponse -> IO (Either a ())) ->
  IO (HM.HashMap ConsumerName (StreamingFetchResponse -> IO (Either a ())))
dispatchRecords records streamSends
  | HM.null streamSends = return HM.empty
  | otherwise = do
    let slen = HM.size streamSends
    Log.debug $ Log.buildString "ready to dispatchRecords to " <> Log.buildInt slen <> " consumers"
    let initVec = V.replicate slen V.empty
    -- recordGroups aggregates the data to be sent by each sender
    let recordGroups =
          V.ifoldl'
            ( \vec idx record ->
                let senderIdx = idx `mod` slen -- Assign the idx-th record to the senderIdx-th sender to send
                    dataSet = vec V.! senderIdx -- get the set of data to be sent by snederIdx-th sender
                    newSet = V.snoc dataSet record -- add idx-th record to dataSet
                 in V.update vec $ V.singleton (senderIdx, newSet)
            )
            initVec
            records

    newSenders <- zipWithM doDispatch (HM.toList streamSends) (V.toList recordGroups)
    return . HM.fromList . catMaybes $ newSenders
  where
    doDispatch (name, sender) record = do
      Log.debug $ Log.buildString "dispatch " <> Log.buildInt (V.length record) <> " records to " <> "consumer " <> Log.buildLazyText name
      sender (StreamingFetchResponse record) >>= \case
        Left err -> do
          -- if send record error, this batch of records will resend next round
          Log.fatal . Log.buildString $ "dispatch error, will remove a consumer: " <> show err
          return Nothing
        Right _ -> do
          return $ Just (name, sender)

doAck ::
  S.LDClient ->
  MVar SubscribeRuntimeInfo ->
  V.Vector RecordId ->
  IO ()
doAck client infoMVar ackRecordIds =
  modifyMVar_
    infoMVar
    ( \info@SubscribeRuntimeInfo {..} -> do
        if sriValid
          then do
            Log.e $ "before handle acks, length of ackedRanges is: " <> Log.buildInt (Map.size sriAckedRanges)
            let newAckedRanges = V.foldl' (\a b -> insertAckedRecordId b sriWindowLowerBound a sriBatchNumMap) sriAckedRanges ackRecordIds
            Log.e $ "after handle acks, length of ackedRanges is: " <> Log.buildInt (Map.size newAckedRanges)
            case tryUpdateWindowLowerBound newAckedRanges sriWindowLowerBound sriBatchNumMap of
              Just (ranges, newLowerBound, checkpointRecordId) -> do
                commitCheckPoint client sriLdCkpReader sriStreamName checkpointRecordId
                Log.info $
                  "update window lower bound, from {" <> Log.buildString (show sriWindowLowerBound)
                    <> "} to "
                    <> "{"
                    <> Log.buildString (show newLowerBound)
                    <> "}"
                return $ info {sriAckedRanges = ranges, sriWindowLowerBound = newLowerBound}
              Nothing ->
                return $ info {sriAckedRanges = newAckedRanges}
          else return info
    )

tryUpdateWindowLowerBound ::
  -- | ackedRanges
  Map.Map RecordId RecordIdRange ->
  -- | lower bound record of current window
  RecordId ->
  -- | batchNumMap
  Map.Map Word64 Word32 ->
  Maybe (Map.Map RecordId RecordIdRange, RecordId, RecordId)
tryUpdateWindowLowerBound ackedRanges lowerBoundRecordId batchNumMap =
  Map.lookupMin ackedRanges >>= \(_, RecordIdRange minStartRecordId minEndRecordId) ->
    if minStartRecordId == lowerBoundRecordId
      then Just (Map.delete minStartRecordId ackedRanges, getSuccessor minEndRecordId batchNumMap, minEndRecordId)
      else Nothing