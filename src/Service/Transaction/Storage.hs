{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PackageImports        #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Service.Transaction.Storage where

import           Control.Exception
import           Control.Monad                         (replicateM)
import qualified Control.Monad.Catch                   as E
-- import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Resource
import           Control.Monad.Trans.State             (StateT, evalStateT, get,
                                                        put)
import           Control.Retry
import qualified Crypto.Hash.SHA256                    as SHA
import qualified Data.ByteString.Base64                as Base64
-- import           Data.Typeable
-- import qualified Data.ByteString.Char8              as BC
import           Control.Concurrent.Chan.Unagi.Bounded
import qualified Data.ByteString.Internal              as BSI
import           Data.Default                          (def)
import           Data.Maybe
import           Data.Pool
import qualified Data.Serialize                        as S (Serialize, decode,
                                                             encode)
-- import           Data.Traversable
import qualified "rocksdb-haskell" Database.RocksDB    as Rocks
import           Node.Data.GlobalLoging
-- import           Node.Node.Types                       (MsgToCentralActor (..))
import           Service.InfoMsg                       (InfoMsg (..),
                                                        LogingTag (..),
                                                        MsgType (..))
import           Service.System.Directory              (getLedgerFilePath,
                                                        getMacroblockFilePath,
                                                        getMicroblockFilePath,
                                                        getTransactionFilePath)
import           Service.Types
import           Service.Types.PublicPrivateKeyPair
import           Service.Types.SerializeJSON           ()

--------------------------------------
-- begin of the Connection section
data DBPoolDescriptor = DBPoolDescriptor {
    poolTransaction :: Pool Rocks.DB
  , poolMicroblock  :: Pool Rocks.DB
  , poolLedger      :: Pool Rocks.DB
  , poolMacroblock  :: Pool Rocks.DB
  }

-- FIX change def (5 times)
connectOrRecoveryConnect :: IO DBPoolDescriptor
connectOrRecoveryConnect = recovering def handler . const $ connectDB


connectDB :: IO DBPoolDescriptor
connectDB = do
  aTx <- getTransactionFilePath
  aMb <- getMicroblockFilePath
  aLd <- getLedgerFilePath
  aMacroblock <- getMacroblockFilePath
  poolTransaction <- createPool (Rocks.open aTx def{Rocks.createIfMissing=True}) Rocks.close 1 32 16
  poolMicroblock  <- createPool (Rocks.open aMb def{Rocks.createIfMissing=True}) Rocks.close 1 32 16
  poolLedger      <- createPool (Rocks.open aLd def{Rocks.createIfMissing=True}) Rocks.close 1 32 16
  poolMacroblock  <- createPool (Rocks.open aMacroblock def{Rocks.createIfMissing=True}) Rocks.close 1 32 16
  -- putStrLn "DBTransactionException"
  -- sleepMs 5000
  -- throw DBTransactionException
  return (DBPoolDescriptor poolTransaction poolMicroblock poolLedger poolMacroblock)


data SuperException = DBTransactionException
                    | NotImplementedException -- test
                    | OtherException
                  deriving (Show)

instance Exception SuperException


--catch all exceptions and retry connections
handler :: [p -> E.Handler IO Bool]
handler =
    [ \_ -> E.Handler $ \(_ :: SomeException) -> do
        return True
    ]

quantityMicroblocksInMacroblock :: Int
quantityMicroblocksInMacroblock = 2
-- End of the Connection section
--------------------------------------


--------------------------------------
-- begin of the Database structure  section

-- for rocksdb Transaction and Microblock
rHashT :: Transaction -> BSI.ByteString
rHashT t@(Transaction {}) = Base64.encode . SHA.hash . S.encode $ t { _timestamp = Nothing }

rHash :: S.Serialize a => a -> BSI.ByteString
rHash key = Base64.encode . SHA.hash . S.encode $ key

lastKeyBlock :: DBKey
lastKeyBlock = "2dJ6lb9JgyQRac0DAkoqmYmS6ats3tND0gKMLW6x2x8=" :: DBKey --read "1"


funW ::  Pool Rocks.DB -> [(DBKey, DBValue)] -> IO ()
funW db aMapKeyValue = do
  let fun = (\aDb -> Rocks.write aDb def{Rocks.sync = True} (map (\(k,v) -> Rocks.Put k v) aMapKeyValue))
  withResource db fun


funR ::  Pool Rocks.DB -> DBKey -> IO (Maybe BSI.ByteString)
funR db key = do
  let fun = (\aDb -> Rocks.get aDb Rocks.defaultReadOptions key)
  withResource db fun

type DBKey = BSI.ByteString
type DBValue = BSI.ByteString
-- end of the Database structure  section
--------------------------------------



getTxs :: DBPoolDescriptor -> MicroblockBD -> IO [TransactionInfo]
getTxs desc mb = do
  let txHashes = _transactionsHashes mb
  print txHashes
  maybeTxUntyped  <- mapM (funR (poolTransaction desc)) txHashes
  print maybeTxUntyped
  let txDoesNotExist = filter (\t -> t /= Nothing) maybeTxUntyped
  if null txDoesNotExist
    then error "Some of transactions can not be found"
    else do
         let txUntyped = map fromJust (filter (isJust) maybeTxUntyped)
         let extract t = case S.decode t :: Either String TransactionInfo of
                            Left e  -> error ("Can not decode TransactionInfo " ++ e)
                            Right r -> r
         let txDecoded = map extract txUntyped
         return txDecoded


getTxsMicroblock :: DBPoolDescriptor -> MicroblockBD -> IO [Transaction]
getTxsMicroblock db mb = do
  txDecoded <- getTxs db mb
  let tx = map (\t -> _tx  (t :: TransactionInfo)) txDecoded
  return tx


getNFirstValuesT :: StateT Rocks.Iterator IO DBValue
getNFirstValuesT = do
  it <- get
  Just v <- Rocks.iterValue it
  Rocks.iterNext it
  put it
  return v


getNFirstValues :: (MonadTrans t, MonadResource (t IO)) => Rocks.DB -> Int -> t IO [DBValue]
getNFirstValues db n = do
  it    <- Rocks.iterOpen db Rocks.defaultReadOptions
  Rocks.iterFirst it
  lift $ evalStateT (replicateM n getNFirstValuesT) it


getNLastValuesT :: StateT Rocks.Iterator IO DBValue
getNLastValuesT = do
  it <- get
  Just v <- Rocks.iterValue it
  Rocks.iterPrev it
  put it
  return v


getNLastValues :: Rocks.DB -> Int -> IO [DBValue]
getNLastValues db n = runResourceT $ do
  it    <- Rocks.iterOpen db Rocks.defaultReadOptions
  Rocks.iterLast it
  lift $ evalStateT (replicateM n getNLastValuesT) it


getFirst :: (MonadResource (t IO), MonadTrans t) => Rocks.DB -> Int -> Int -> t IO [DBValue]
getFirst db offset count = drop offset <$> getNFirstValues db (offset + count )

getLast :: Rocks.DB -> Int -> Int -> IO [(DBKey, DBValue)]
-- getLast db  offset count = drop offset <$> getNLastValues db (offset + count )
getLast db  offset count = drop offset <$> getNLastValues2 db (offset + count )


getNLastValues2 :: Rocks.DB -> Int -> IO [(DBKey, DBValue)]
getNLastValues2 db n = runResourceT $ do
  it    <- Rocks.iterOpen db Rocks.defaultReadOptions
  Rocks.iterLast it
  _ <- replicateM (n - 1) $ Rocks.iterPrev it
  Rocks.iterItems it

-- getChainInfoDB = undefined
getChainInfoDB :: DBPoolDescriptor -> InChan InfoMsg -> IO ChainInfo
getChainInfoDB desc aInfoChan = do
  print lastKeyBlock
  key <- funR (poolMacroblock desc) lastKeyBlock
  mByte <- case key of Nothing -> return Nothing
                       Just k  -> funR (poolMacroblock desc) k
  mb <- case mByte of Nothing -> do
                        writeLog aInfoChan [BDTag] Error "No Key block "
                        return Nothing
                      Just k -> case (S.decode k :: Either String MacroblockBD) of
                                   Left _  -> error "Can not decode Macroblock"
                                   Right r -> return $ Just r
  tMacroblock2ChainInfo key mb

-- getChainInfoDB desc aInfoChan = do
--   let bd = (poolMacroblock desc)
--   let fun = (\db -> runResourceT $ do
--                 it    <- Rocks.iterOpen db Rocks.defaultReadOptions
--                 Rocks.iterLast it
--                 return it)
--   iter <- withResource bd fun
--   (key, mb) <- getLastKeyBlock bd iter aInfoChan
--   -- tMacroblock2ChainInfo key mb

--   return ( undefined :: ChainInfo)
-- --   (key, mb ) <- getLastKeyBlock desc aInfoChan 0 1
-- --   -- let true = length (_mblocks (mb :: MacroblockBD)) == length (_teamKeys (mb :: MacroblockBD))

-- -- getLastKeyBlock = undefined
-- getLastKeyBlock :: Pool Rocks.DB -> Rocks.Iterator -> InChan InfoMsg -> IO (Maybe DBKey, Maybe MacroblockBD)
-- getLastKeyBlock bd it aInfoChan = do
--   value <- Rocks.iterValue it
--   key <- Rocks.iterKey it
--   let res = case value of Nothing -> do
--                              -- writeLog aInfoChan [BDTag] Error "No Key block "
--                              Nothing
--                           Just k -> case (S.decode k :: Either String MacroblockBD) of
--                                        Left _  -> error "Can not decode Microblock"
--                                        Right r -> Just r
--   return (key,res)
--   -- return undefined

getLastTransactions :: DBPoolDescriptor -> PublicKey -> Int -> Int -> IO [TransactionAPI]
getLastTransactions descr pubKey offset aCount = do
  let fun = \db -> getLast db offset aCount
  txs <- withResource (poolTransaction descr) fun
  let rawTxInfo = map (\(_,v) -> v) txs
  let txAPI = decodeTransactionsAndFilterByKey rawTxInfo pubKey
  return txAPI


getMicroBlockByHashDB :: DBPoolDescriptor -> Hash -> IO (Maybe MicroblockBD)
getMicroBlockByHashDB db mHash = do
  mbByte <- getByHash (poolMicroblock db) mHash
  case mbByte of Nothing -> return Nothing
                 Just m -> case (S.decode m :: Either String MicroblockBD) of
                   Left _   -> error "Can not decode Microblock"
                   Right rm -> return $ Just rm


getTransactionsByMicroblockHash :: DBPoolDescriptor -> Hash -> IO (Maybe [TransactionInfo])
getTransactionsByMicroblockHash db aHash = do
  mb <- getMicroBlockByHashDB db aHash
  case mb of
    Nothing -> return Nothing
    Just m@(MicroblockBD {..}) -> do
      txInfo <- getTxs db m
      return $ Just txInfo

getBlockByHashDB :: DBPoolDescriptor -> Hash -> InChan InfoMsg -> IO (Maybe MicroblockAPI)
getBlockByHashDB db hash _ = do
  mb <- getMicroBlockByHashDB db hash
  case mb of
    Nothing -> return Nothing
    Just m  -> do
      mAPI <- tMicroblockBD2MicroblockAPI db m --aInfoChan
      return $ Just mAPI


getKeyBlockByHashDB :: DBPoolDescriptor -> Hash -> InChan InfoMsg -> IO (Maybe MacroblockAPI)
getKeyBlockByHashDB db kHash _ = do
  kb <- getByHash (poolMacroblock db) kHash
  case kb of Nothing -> return Nothing
             Just j -> case (S.decode j :: Either String MacroblockBD) of
               Left _  -> error "Can not decode MacroblockBD"
               Right r -> do
                 -- print r
                 -- mAPI <- tMacroblock2MacroblockAPI db r
                 -- print mAPI
                 -- print "Hello"
                 Just <$> (tMacroblock2MacroblockAPI db r)


getTransactionByHashDB :: DBPoolDescriptor -> Hash -> IO (Maybe TransactionInfo) --Transaction
getTransactionByHashDB db tHash = do
  tx <- getByHash (poolTransaction db) tHash
  case tx of Nothing -> return Nothing
             Just j -> case (S.decode j :: Either String  TransactionInfo) of
               Left _   -> error "Can not decode TransactionInfo"
               Right rt -> return $ Just rt


getByHash :: Pool Rocks.DB -> Hash -> IO (Maybe DBValue)
getByHash pool aHash = (\(Hash key) -> funR pool key) aHash


decodeTransactionsAndFilterByKey :: [DBValue] -> PublicKey -> [TransactionAPI]
decodeTransactionsAndFilterByKey rawTx pubKey = txAPI
  where fun = \t -> case (S.decode t :: Either String TransactionInfo) of
                       Left _   -> error "Can not decode TransactionInfo"
                       Right rt -> Just rt

        txInfo = map fun rawTx
        txWithouMaybe = map fromJust (filter (isJust) txInfo)
        tx = map (\t -> _tx (t  :: TransactionInfo) ) txWithouMaybe
        txWithKey = filter (\t -> (_owner t == pubKey || _receiver t == pubKey)) tx
        txAPI = map (\t -> TransactionAPI { _tx = t, _txHash = rHashT t}) txWithKey


getAllTransactionsDB :: DBPoolDescriptor -> PublicKey -> IO [TransactionAPI]
getAllTransactionsDB descr pubKey = do
  txByte <- withResource (poolTransaction descr) getAllValues
  return $ decodeTransactionsAndFilterByKey txByte pubKey


getAllValues :: MonadUnliftIO m => Rocks.DB -> m [DBValue]
getAllValues db = runResourceT $ do
  it    <- Rocks.iterOpen db Rocks.defaultReadOptions
  Rocks.iterFirst it
  Rocks.iterValues it


getAllItems :: MonadResource m => Rocks.DB -> m [(DBKey, DBValue)]
getAllItems db = do
  it    <- Rocks.iterOpen db Rocks.defaultReadOptions
  Rocks.iterFirst it
  Rocks.iterItems it


tMicroblockBD2Microblock :: DBPoolDescriptor -> MicroblockBD -> IO Microblock
tMicroblockBD2Microblock db m@(MicroblockBD {..}) = do
  tx <- getTxsMicroblock db m
  teamKeys <- getTeamKeysForMicroblock db _keyBlock
  return Microblock {
  _keyBlock,
  _sign          = _signBD,
  -- _teamKeys,
  _teamKeys = teamKeys,
  _publisher,
  _transactions  = tx,
  _numOfBlock
  }

tMicroblock2MicroblockBD :: Microblock -> MicroblockBD
tMicroblock2MicroblockBD (Microblock {..}) = MicroblockBD {
  _keyBlock,
  _signBD = _sign,
  -- _teamKeys,
  _publisher,
  _transactionsHashes = map rHashT _transactions,
  _numOfBlock }

-- getTeamKeysForMicroblock :: DBPoolDescriptor -> DBKey -> InChan InfoMsg -> IO [PublicKey]
getTeamKeysForMicroblock :: DBPoolDescriptor -> DBKey -> IO [PublicKey]
getTeamKeysForMicroblock db aHash = do
  mb <- getByHash (poolMacroblock db) (Hash aHash)
  case mb of Nothing -> do
               -- writeLog aInfoChan [BDTag] Error ("No Team Keys For Key block " ++ show aHash)
               return []
             Just j -> case (S.decode j :: Either String MacroblockBD) of
               Left _  -> error "Can not decode Macroblock"
               Right r -> return $ _teamKeys (r :: MacroblockBD)


-- tMicroblockBD2MicroblockAPI :: DBPoolDescriptor -> MicroblockBD -> InChan InfoMsg -> IO MicroblockAPI
tMicroblockBD2MicroblockAPI :: DBPoolDescriptor -> MicroblockBD -> IO MicroblockAPI
tMicroblockBD2MicroblockAPI db m@(MicroblockBD {..}) = do
  tx <- getTxsMicroblock db m
  let txAPI = map (\t -> TransactionAPI {_tx = t, _txHash = rHashT t }) tx
  -- teamKeys <- getTeamKeysForMicroblock db _keyBlock --aInfoChan
  return MicroblockAPI {
            _prevMicroblock = "",
            _nextMicroblock = "",
            _keyBlock,
            _signAPI = _signBD,
            -- _teamKeys = teamKeys,
            _publisher, -- =  _publisher,-- = read "1" :: PublicKey,
            _transactionsAPI = txAPI
            }


tMacroblock2MacroblockAPI :: DBPoolDescriptor -> MacroblockBD -> IO MacroblockAPI
tMacroblock2MacroblockAPI descr (MacroblockBD {..}) = do
           microblocks <- zip _mblocks <$> mapM (\h -> fromJust <$> getMicroBlockByHashDB descr (Hash h)) _mblocks
           let microblocksInfoAPI = map (\(h, MicroblockBD {..}) -> MicroblockInfoAPI {
                                                        _prevMicroblock = "",
                                                        _nextMicroblock = "",
                                                        _keyBlock,
                                                        _signAPI = _signBD,
                                                        _publisher,
                                                        _hash = h}) microblocks
           return $ MacroblockAPI {
             _prevKBlock,
             _nextKBlock = "",
             _difficulty,
             _height,
             _solver,
             _reward,
             _mblocks = microblocksInfoAPI,
             _teamKeys }


dummyMacroblock :: MacroblockBD
dummyMacroblock = MacroblockBD {
  _prevKBlock = "",
  _difficulty = 0,
  _height = 0,
  _solver = aSolver,
  _reward = 0,
  _time = 0,
  _number = 0,
  _nonce = 0,
  _mblocks = [],
  _teamKeys = []
}
  where aSolver = read "1" :: PublicKey


tKeyBlockInfo2Macroblock :: KeyBlockInfo -> MacroblockBD
tKeyBlockInfo2Macroblock (KeyBlockInfo {..}) = MacroblockBD {
            _prevKBlock = _prev_hash,
            _difficulty = 20,
            _height = 0,
            _solver,
            _reward = 0,
            _time,
            _number,
            _nonce,
            _mblocks = [],
            _teamKeys = []
          }


tMacroblock2ChainInfo :: Maybe DBKey -> Maybe MacroblockBD -> IO ChainInfo
tMacroblock2ChainInfo keyBlockHash m = do
  case m of Nothing ->  return ChainInfo {
    _emission        = 0,
    _curr_difficulty = 0,
    _last_block      = "",
    _blocks_num      = 0,
    _txs_num         = 0,  -- quantity of all approved transactions
    _nodes_num       = 0   -- quantity of all active nodes
    }
            Just (MacroblockBD {..})  -> return ChainInfo {
    _emission        = _reward,
    _curr_difficulty = _difficulty,
    _last_block      = fromJust keyBlockHash,
    _blocks_num      = 0,
    _txs_num         = 0,  -- quantity of all approved transactions
    _nodes_num       = 0   -- quantity of all active nodes
    }
