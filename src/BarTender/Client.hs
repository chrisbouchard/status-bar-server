-- | A client for the status bar server
module BarTender.Client
    ( BarClient
    , ConnectionOptions(..)
    , defaultConnectionOptions
    , connectClient
    , runClient
    , touchClient
    , updateClient
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Exception.Base
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Control.Monad.STM

import Network.Socket

import System.IO
import System.Log.Logger
import System.Log.Handler.Simple
import System.Timeout

import BarTender.Message

data BarServerInfo = BarServerInfo
    { serverSock    :: Socket
    , serverCid     :: Int
    , serverTimeout :: Int
    , serverVersion :: Int
    }
    deriving Show

data BarClientInfo = BarClientInfo
    { clientName       :: String
    , clientServer     :: Maybe BarServerInfo
    , clientConnection :: Maybe ConnectionOptions
    }
    deriving Show

type BarClient m a = StateT BarClientInfo m a

data ConnectionOptions = ConnectionOptions
    { connectHost    :: String
    , connectPort    :: String
    , connectRetries :: Int
    , connectTimeout :: Int
    }
    deriving Show

-- | Default options for connecting to a server
defaultConnectionOptions :: ConnectionOptions
defaultConnectionOptions = ConnectionOptions
    { connectHost    = "localhost"
    , connectPort    = "9999"
    , connectRetries = 3
    , connectTimeout = 60
    }

-- | Run a client monad
runClient :: MonadIO m
          => String        -- ^ The name of the client
          -> BarClient m a -- ^ The bar client monad to run
          -> m a
runClient name client = evalStateT client (BarClientInfo name Nothing Nothing)

-- | Connect a client to a status bar server
connectClient :: MonadIO m
              => ConnectionOptions
              -> BarClient m ()
connectClient options = do
    BarClientInfo { clientName = name } <- get

    mServerInfo <- liftIO . withSocketsDo $ do
        debugM "ServerBar.Client.connectBar" $ "Enter"
        serverinfo <- head <$> getAddrInfo
            (Just defaultHints { addrFlags = [AI_PASSIVE] , addrSocketType = Datagram })
            (Just $ connectHost options) (Just $ connectPort options)
        debugM "ServerBar.Client.connectBar" $ "serverinfo: " ++ show serverinfo

        let serveraddr = addrAddress serverinfo

        debugM "ServerBar.Client.connectBar" $ "Attempting socket"
        sock <- socket (addrFamily serverinfo) (addrSocketType serverinfo) defaultProtocol
        debugM "ServerBar.Client.connectBar" $ "sock: " ++ show sock

        debugM "ServerBar.Client.connectBar" $ "Attempting connection"
        connect sock serveraddr

        debugM "ServerBar.Client.connectBar" $ "Connected socket"

        mMessage <- attempt (connectTimeout options) (connectRetries options) $ do
            debugM "ServerBar.Client.connectBar" $ "Sending init message"
            send sock . show $ RInit name
            message <- parseMessage <$> recv sock bufferSize
            debugM "ServerBar.Client.connectBar" $ "Received from server: " ++ (show message)
            return message

        case mMessage of
            Nothing      -> return Nothing
            Just message -> handleAck sock message

    modify $ \state -> state { clientServer = mServerInfo }

    where
        bufferSize = 1024

        seconds = 10 ^ 6

        -- Try an action a given number of times, failing on exception or after
        -- a specified timeout.
        attempt :: Int -> Int -> IO a -> IO (Maybe a)
        attempt waitTime 0 action = return Nothing
        attempt waitTime n action = do
            result <- catch (timeout (waitTime * seconds) action)
                            (\(e :: IOException) -> return Nothing)
            case result of
                Just x  -> return $ Just x
                Nothing -> attempt waitTime (n - 1) action

        handleAck :: Socket -> Message -> IO (Maybe BarServerInfo)
        handleAck sock (RAck cid timeout version) = return . Just $
            BarServerInfo { serverSock    = sock
                          , serverCid     = cid
                          , serverTimeout = timeout
                          , serverVersion = version
                          }
        handleAck sock message = do
            shutdown sock ShutdownBoth
            errorM "ServerBar.Client.handleAck" $ "Server did not respond with Ack"
            errorM "ServerBar.Client.handleAck" $ "    response: " ++ show message
            return Nothing

-- | Send an alive message to the server
touchClient :: MonadIO m
            => BarClient m ()
touchClient = do
    BarClientInfo { clientName = name, clientServer = mServerInfo } <- get
    liftIO . withSocketsDo $ case mServerInfo of
        Nothing -> do
            errorM "ServerBar.Client.sendUpdate" $ "Connection is closed"
        (Just serverInfo) -> do
            -- TODO: We should probably check this return value
            void $ send (serverSock serverInfo) . show $ RAlive (serverCid serverInfo)

-- | Send an update to the server
updateClient :: MonadIO m
             => String    -- ^ The content of the update
             -> BarClient m ()
updateClient content = do
    BarClientInfo { clientName = name, clientServer = mServerInfo } <- get
    liftIO . withSocketsDo $ case mServerInfo of
        Nothing -> do
            errorM "ServerBar.Client.sendUpdate" $ "Connection is closed"
        (Just serverInfo) -> do
            -- TODO: We should probably check this return value
            void $ send (serverSock serverInfo) . show $ RUpdate (serverCid serverInfo) content
