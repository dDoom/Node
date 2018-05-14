{-# LANGUAGE OverloadedStrings, LambdaCase, ScopedTypeVariables #-}

module Main where

import              Control.Monad
import              Control.Concurrent
import              System.Environment (getEnv)
import              Data.List.Extra

import              Node.Node.Mining
import              Node.Node.Types
import              Service.Timer
import              Node.Lib
import              Service.InfoMsg
import              Service.Network.Base
import              PoA.PoAServer
import              CLI.CLI (serveRpc)
import              Control.Exception (try, SomeException())

import              Data.Aeson
import qualified    Data.ByteString.Lazy as L

main :: IO ()
main =  do
        enc <- L.readFile "configs/config.json"
        case decode enc :: Maybe BuildConfig of
          Nothing   -> error "Please, specify config file correctly"
          Just conf -> do

            aExitCh   <- newChan
            aAnswerCh <- newChan
            aInfoCh   <- newChan

            void $ startNode conf
                aExitCh aAnswerCh aInfoCh managerMining $ \ch aChan aMyNodeId aFileChan -> do
                    -- periodically check current state compare to the whole network state
                    metronomeS 400000 (writeChan ch connectivityQuery)
                    metronomeS 1000000 (writeChan ch queryPositions)
                    metronomeS 1000000 (writeChan ch deleteOldestMsg)
                    metronomeS 1000000 (writeChan ch deleteOldestPoW)
                    poa_in  <- try (getEnv "poaInPort") >>= \case
                            Right item              -> return $ read item
                            Left (_::SomeException) -> case simpleNodeBuildConfig conf of
                                 Nothing   -> error "Please, specify SimpleNodeConfig"
                                 Just snbc -> return $ poaInPort snbc

                    rpc_p   <- try (getEnv "rpcPort") >>= \case
                            Right item              -> return $ read item
                            Left (_::SomeException) -> case simpleNodeBuildConfig conf of
                                 Nothing   -> error "Please, specify SimpleNodeConfig"
                                 Just snbc -> return $ rpcPort snbc

                    stat_h  <- try (getEnv "statsdHost") >>= \case
                            Right item              -> return item
                            Left (_::SomeException) -> return $ host $ statsdBuildConfig conf

                    stat_p  <- try (getEnv "statsdPort") >>= \case
                            Right item              -> return $ read item
                            Left (_::SomeException) -> return $ port $ statsdBuildConfig conf

                    logs_h  <- try (getEnv "logHost") >>= \case
                            Right item              -> return item
                            Left (_::SomeException) -> return $ host $ logsBuildConfig conf

                    logs_p  <- try (getEnv "logPort") >>= \case
                            Right item              -> return $ read item
                            Left (_::SomeException) -> return $ port $ logsBuildConfig conf

                    log_id  <- try (getEnv "log_id") >>= \case
                        Right item              -> return item
                        Left (_::SomeException) -> return $ show aMyNodeId

                    void $ forkIO $ serveInfoMsg (ConnectInfo stat_h stat_p) (ConnectInfo logs_h logs_p) aInfoCh log_id

                    void $ forkIO $ servePoA poa_in aMyNodeId ch aChan aInfoCh aFileChan
                    void $ forkIO $ serveRpc rpc_p ch aInfoCh

                    --when (takeEnd 3 log_id == "175") $
                    metronomeS 10000000 (writeChan ch testBroadcastBlockIndex)


                    writeChan aInfoCh $ Metric $ increment "cl.node.count"

            void $ readChan aExitCh
