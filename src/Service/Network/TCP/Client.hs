{-#Language TypeSynonymInstances, FlexibleInstances#-}
module Service.Network.TCP.Client (
    ConnectInfo(..),
    runClient,
    PortNumber(..),
    HostAddress,
    openConnect,
    closeConnect
  ) where

import Network.Socket
import Service.Network.Base


class Hosts a where
    openConnect :: a -> PortNumber -> IO ClientHandle

closeConnect :: ClientHandle -> IO ()
closeConnect = close . clientSocket

-- | Run a TCP client.
runClient :: Hosts a => a -> PortNumber -> (ClientHandle -> IO ()) -> IO ()
runClient aHostAdress aPort aPlainHandler = withSocketsDo $ do
    aHandle <- openConnect aHostAdress aPort
    aPlainHandler aHandle
    closeConnect aHandle

instance Hosts HostAddress where
    openConnect aHostAdress = openConnect (showHostAddress aHostAdress)

instance Hosts String where
    openConnect aHostAdress aPort = do
        aServerAddr <- head <$> getAddrInfo
            Nothing
            (Just aHostAdress)
            (Just $ show aPort)
        aSocket <- socket (addrFamily aServerAddr) Stream defaultProtocol
        connect aSocket $ addrAddress aServerAddr
        return $ ClientHandle aSocket (addrAddress aServerAddr)
