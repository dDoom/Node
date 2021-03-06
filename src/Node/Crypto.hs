{-# LANGUAGE ScopedTypeVariables, PackageImports, LambdaCase #-}
module Node.Crypto where

import              Node.Data.Key hiding (PublicKey(..))

import              Crypto.Error
import              Crypto.Cipher.Types
import              Crypto.Random.Types
import "cryptonite" Crypto.Hash
import              Crypto.PubKey.ECC.DH
import              Crypto.PubKey.ECC.ECDSA

import              Crypto.Cipher.AES   (AES256)
import              Data.ByteArray (unpack)

import              Data.ByteString (ByteString, pack)
import              Data.Serialize
{-
makeConnectingRequest
    ::  MyNodeId
    ->  PublicPoint
    ->  PortNumber
    ->  PrivateKey
    ->  IO Package
makeConnectingRequest aMyNodeId aPublicPoint aPortNumber aPrivateKey =
    Unciphered . ConnectingRequest aPublicPoint aMyNodeId aPortNumber<$>
        signEncodeble aPrivateKey
            (aPublicPoint, aMyNodeId, aPortNumber, "ConnectingRequest")

--
verifyConnectingRequest :: Package -> Bool
verifyConnectingRequest = \case
    Unciphered
        (ConnectingRequest aPublicPoint aMyNodeId aPortNumber aSignature) ->
            verifyEncodeble (idToKey $ toNodeId aMyNodeId)
                aSignature
                    (aPublicPoint, aMyNodeId, aPortNumber, "ConnectingRequest")
    _ -> False


disconnectRequest :: Package
disconnectRequest = Unciphered $ DisconnectRequest []


makeCipheredPackage :: Ciphered -> StringKey -> CryptoFailable Package
makeCipheredPackage aCiphered aStringKey = do
    encryptedMsg <- encrypt aStringKey $ encode aCiphered
    pure $ Ciphered (fromByteString encryptedMsg)


makeBroadcastRequest :: BroadcastThing -> PrivateKey -> MyNodeId -> IO Ciphered
makeBroadcastRequest aBroadcastThing aPrivateKey aMyNodeId = do
    aTime       <- getTime Realtime
    aSignature  <- signEncodeble aPrivateKey (aMyNodeId, aTime, aBroadcastThing)
    pure $ BroadcastRequest
        (PackageSignature aMyNodeId aTime aSignature)
        aBroadcastThing


decryptChipred :: StringKey -> CipheredString -> Maybe Ciphered
decryptChipred aSecretKey aChipredString = case decode <$> aDecryptedString of
    Just (Right aChipred) -> Just aChipred
    _                     -> Nothing
  where
    aDecryptedString = maybeCryptoError $
        encrypt aSecretKey (toByteString aChipredString)
-}

verifyEncodeble :: Serialize msg => PublicKey -> Signature -> msg -> Bool
verifyEncodeble aPublicKey aSignature aMsg = verify SHA3_256
    aPublicKey aSignature (encode aMsg)

signEncodeble :: (MonadRandom m, Serialize msg) =>
    PrivateKey
    -> msg
    -> m Signature
signEncodeble aPrivateKey aMsg = sign aPrivateKey SHA3_256 (encode aMsg)

genKeyPair :: MonadRandom m => Curve -> m (PrivateNumber, PublicPoint)
genKeyPair cur = do
    aPrivateKey <- generatePrivate cur
    pure (aPrivateKey, calculatePublic cur aPrivateKey)


encrypt :: StringKey -> ByteString -> CryptoFailable ByteString
encrypt (StringKey secretKey) aMsg = do
    cipher :: AES256 <- cipherInit secretKey
    return $ ctrCombine cipher nullIV aMsg


cryptoHash :: Serialize a => a -> ByteString
cryptoHash = pack . unpack . fastHash

fastHash :: Serialize a => a -> Digest SHA3_512
fastHash bs = hash $ encode bs :: Digest SHA3_512
