{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, DeriveGeneric #-}

module CLI.Common (
  sendMessageTo,
  sendMessageBroadcast,
  loadMessages,

  sendTrans,
  sendNewTrans,
  generateNTransactions,
  generateTransactionsForever,
  getNewKey,
  getBlockByHash,
  getTransactionByHash,
  getAllTransactions,
  getBalance,
  getPublicKeys,

  CLIException(..),
  Result

  )where

import Control.Monad (forever, replicateM)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Chan
import Control.Exception
import Data.Time.Units
import Data.List.Split (splitOn)
import Data.Map (fromList, lookup, Map)
import System.Random (randomRIO)

import Service.Transaction.Balance
import Service.Transaction.TransactionsDAG
import Node.Node.Types
import Service.Types
import Service.Types.SerializeJSON ()
import Service.Types.PublicPrivateKeyPair
import Service.InfoMsg
import Service.System.Directory (getTime, getKeyFilePath)
import Service.Transaction.Storage (DBPoolDescriptor(..))
import Service.Transaction.Common as B (getBlockByHashDB, getTransactionByHashDB)

type Result a = Either CLIException a

data CLIException = WrongKeyOwnerException
                  | NotImplementedException -- test
                  | OtherException
  deriving Show

instance Exception CLIException

sendMessageTo :: ManagerMiningMsg a => MsgTo -> Chan a -> IO (Result ())
sendMessageTo ch = return $ return $ Left NotImplementedException

sendMessageBroadcast :: ManagerMiningMsg a => String -> Chan a -> IO (Result ())
sendMessageBroadcast ch = return $ return $ Left NotImplementedException

loadMessages :: ManagerMiningMsg a => Chan a -> IO (Result [MsgTo])
loadMessages ch = return $ Left NotImplementedException

getBlockByHash :: ManagerMiningMsg a => DBPoolDescriptor -> Hash -> Chan a -> IO (Result Microblock)
getBlockByHash db hash ch = return =<< Right <$> B.getBlockByHashDB db hash


getTransactionByHash :: ManagerMiningMsg a => DBPoolDescriptor -> Hash -> Chan a -> IO (Result TransactionInfo)
getTransactionByHash db hash ch = return =<< Right <$> B.getTransactionByHashDB db hash


getAllTransactions :: ManagerMiningMsg a => PublicKey -> Chan a -> IO (Result [Transaction])
getAllTransactions key ch = return $ Left NotImplementedException



sendTrans :: ManagerMiningMsg a => Transaction -> Chan a -> Chan InfoMsg -> IO (Result ())
sendTrans tx ch aInfoCh = try $ do
  sendMetrics tx aInfoCh
  writeChan ch $ newTransaction tx

sendNewTrans :: ManagerMiningMsg a => Trans -> Chan a -> Chan InfoMsg -> IO (Result Transaction)
sendNewTrans trans ch aInfoCh = try $ do
  let moneyAmount = (Service.Types.txAmount trans) :: Amount
  let receiverPubKey = recipientPubKey trans
  let ownerPubKey = senderPubKey trans
  timePoint <- getTime
  keyPairs <- getSavedKeyPairs
  let mapPubPriv = fromList keyPairs :: (Map PublicKey PrivateKey)
  case (Data.Map.lookup ownerPubKey mapPubPriv) of
    Nothing -> do
      throw WrongKeyOwnerException
    Just ownerPrivKey -> do
      sign  <- getSignature ownerPrivKey moneyAmount
      let tx  = Transaction ownerPubKey receiverPubKey moneyAmount ENQ timePoint sign
      _ <- sendTrans tx ch aInfoCh
      return tx


genNTx :: Int -> IO [Transaction]
genNTx n = do
   let quantityOfKeys = if qKeys <= 2 then 2 else qKeys
                        where qKeys = div n 3
   keys <- replicateM quantityOfKeys generateNewRandomAnonymousKeyPair
   tx <- getTransactions keys n
   return tx

generateNTransactions :: ManagerMiningMsg a =>
    QuantityTx -> Chan a -> Chan InfoMsg -> IO (Result ())
generateNTransactions qTx ch m = try $ do
  tx <- genNTx qTx
  mapM_ (\x -> do
          writeChan ch $ newTransaction x
          sendMetrics x m
        ) tx
  putStrLn "Transactions are created"


generateTransactionsForever :: ManagerMiningMsg a => Chan a -> Chan InfoMsg -> IO (Result ())
generateTransactionsForever ch m = try $ forever $ do
                                quantityOfTranscations <- randomRIO (20,30)
                                tx <- genNTx quantityOfTranscations
                                mapM_ (\x -> do
                                            writeChan ch $ newTransaction x
                                            sendMetrics x m
                                       ) tx
                                threadDelay (10^(6 :: Int))
                                putStrLn ("Bundle of " ++ show quantityOfTranscations ++"Transactions was created")

getNewKey :: IO (Result PublicKey)
getNewKey = try $ do
  (KeyPair aPublicKey aPrivateKey) <- generateNewRandomAnonymousKeyPair
  getKeyFilePath >>= (\keyFileName -> appendFile keyFileName (show aPublicKey ++ ":" ++ show aPrivateKey ++ "\n"))
  putStrLn ("Public Key " ++ show aPublicKey ++ " was created")
  return aPublicKey


getBalance :: DBPoolDescriptor -> PublicKey -> Chan InfoMsg -> IO (Result Amount)
getBalance descrDB key aInfoCh = try $ do
    stTime  <- ( getCPUTimeWithUnit :: IO Millisecond )
    result  <- getBalanceForKey descrDB pKey
    endTime <- ( getCPUTimeWithUnit :: IO Millisecond )
    writeChan aInfoCh $ Metric $ timing "cl.ld.time" (subTime stTime endTime)
    return result


getSavedKeyPairs :: IO [(PublicKey, PrivateKey)]
getSavedKeyPairs = do
  result <- try $ getKeyFilePath >>= (\keyFileName -> readFile keyFileName)
  case result of
    Left ( _ :: SomeException) -> do
          putStrLn "There is no keys"
          return []
    Right keyFileContent       -> do
          let rawKeys = lines keyFileContent
          let keys = map (splitOn ":") rawKeys
          let pairs = map (\x -> (,) (read (x !! 0) :: PublicKey) (read (x !! 1) :: PrivateKey)) keys
          return pairs


getPublicKeys :: IO (Result [PublicKey])
getPublicKeys = try $ do
  pairs <- getSavedKeyPairs
  return $ map fst pairs


sendMetrics :: Transaction -> Chan InfoMsg -> IO ()
sendMetrics (Transaction o r a _ _ _) m = do
                           writeChan m $ Metric $ increment "cl.tx.count"
                           writeChan m $ Metric $ set "cl.tx.wallet" o
                           writeChan m $ Metric $ set "cl.tx.wallet" r
                           writeChan m $ Metric $ gauge "cl.tx.amount" a
