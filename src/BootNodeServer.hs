{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module BootNodeServer (
    bootNodeServer
) where

import           Control.Concurrent.Chan.Unagi.Bounded
import           Control.Monad                         (forever, void, when, forM_)
import qualified Data.Text                             as T
import qualified Network.WebSockets                    as WS
import           Service.InfoMsg                       as I
import           Service.Network.Base
import           Service.Network.WebSockets.Client
import           Service.Network.WebSockets.Server
import qualified Control.Concurrent                    as C
import           Control.Exception
import           Data.Aeson                            as A
import           Data.Maybe                            ()
import           Node.Data.GlobalLoging
import           Node.DataActor
import           Node.NetLvl.Massages
import           Service.System.Version

data ConnectTesterActor = AddConnectToList Connect | TestExistedConnect Connect


-- Send to periodic to connect tester actor abou checking of the connects.
bootNodeTimer :: InChan (DataActorRequest Connect) -> InChan ConnectTesterActor -> IO b
bootNodeTimer aChanOfDataActor aConnectTesterActorInChan = forever $ do
    C.threadDelay 60000000
    -- Tag: write to aChanOfDataActor
    aConnects <- getRecords aChanOfDataActor
    forM_ aConnects (tryWriteChan aConnectTesterActorInChan . TestExistedConnect)


-- Test of connect state.
connectTesterActor :: OutChan ConnectTesterActor -> InChan (DataActorRequest Connect) -> IO ()
connectTesterActor aConnectTesterActorOutChan aChanOfDataActor =
    -- Tag: read from aConnectTesterActorChan
    forever $ readChan aConnectTesterActorOutChan >>= \case
        AddConnectToList aConn@(Connect aHostAdress aPort) -> void $ C.forkIO $ do
            C.threadDelay 3000000
            runClient (showHostAddress aHostAdress) (fromEnum aPort) "/" $
                -- Tag: write to aChanOfDataActor
                \_ -> void $ tryWriteChan aChanOfDataActor $ AddRecords [aConn]

        TestExistedConnect aConn@(Connect aHostAdress aPort) -> void $ C.forkIO $ do
            -- Tag: write to aChanOfDataActor
            aConnects <- getRecords aChanOfDataActor
            when (aConn`elem`aConnects) $ do
                aOk <- try $ runClient (showHostAddress aHostAdress) (fromEnum aPort) "/" $ \_ -> return ()
                case aOk of
                    Left (_ :: SomeException) ->
                        -- Tag: write to aChanOfDataActor
                        void $ tryWriteChan aChanOfDataActor $ DeleteRecords aConn
                    _ -> return ()


bootNodeServer :: PortNumber -> InChan InfoMsg -> InChan (DataActorRequest Connect) -> IO ()
bootNodeServer aRecivePort aInfoChan aChanOfDataActor = do
    writeLog aInfoChan [ServerBootNodeTag, InitTag] Info $
        "Init. ServerPoABootNode: a port is " ++ show aRecivePort

    (aConnectTesterActorInChan, aConnectTesterActorOutChan) <- newChan 64
    void $ C.forkIO $ bootNodeTimer aChanOfDataActor aConnectTesterActorInChan
    void $ C.forkIO $ connectTesterActor aConnectTesterActorOutChan aChanOfDataActor

    runServer aRecivePort "bootNodeServer" $ \aHostAdress aPending -> do
        aConnect <- WS.acceptRequest aPending
        let aSend = WS.sendTextData aConnect . A.encode
            aLog  = writeLog aInfoChan [ServerBootNodeTag] Info
            aSenToActor = void . tryWriteChan aConnectTesterActorInChan
            aFilter = filter (\(Connect aAdress _) -> aHostAdress /= aAdress)

        aLog "ServerPoABootNode.Connect accepted."
        aMsg <- WS.receiveData aConnect
        case A.eitherDecodeStrict aMsg of
            Right a -> case a of
                RequestVersion -> do
                    aLog  $ "Version request from client node."
                    aSend $ ResponseVersion $(version)

                RequestPotentialConnects aFull
                    | aFull -> do
                        aLog "Accepted request full list of connections."
                        -- Tag: write to aChanOfDataActor
                        aConnects <- getRecords aChanOfDataActor
                        aSend $ ResponsePotentialConnects $ aFilter aConnects

                    | otherwise -> do
                        aLog "Accepted request of connections."
                        -- Tag: write to aChanOfDataActor
                        aConnects <- getRecords aChanOfDataActor
                        aSend $ ResponsePotentialConnects $ aFilter aConnects

                ActionAddToConnectList aPort ->
                    -- Tag: write to aConnectTesterActorChan
                    aSenToActor $ AddConnectToList (Connect aHostAdress aPort)

                ActionConnectIsDead aDeadConnect ->
                    -- Tag: write to aConnectTesterActorChan
                    aSenToActor $ TestExistedConnect aDeadConnect

                _  -> writeLog aInfoChan [ServerBootNodeTag] Warning $
                    "Broken message from PP " ++ show aMsg
            Left a -> do
                WS.sendTextData aConnect $ T.pack ("{\"tag\":\"Response\",\"type\":\"Error\", \"reason\":\"" ++ a ++ "\", \"Msg\":" ++ show aMsg ++"}")
                writeLog aInfoChan [ServerBootNodeTag] Warning $
                    "Broken message from PP " ++ show aMsg ++ " " ++ a ++ showHostAddress aHostAdress
