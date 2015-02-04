{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WebSockets as WaiWS
import qualified Network.WebSockets as WS
import qualified Network.HTTP.Types.Status as Status
import qualified Network.HTTP.Types.Header as Header
--import qualified Data.ByteString as BS
--import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBC
import qualified Data.Text as T
--import qualified Data.Text.IO as T
--import qualified Data.Text.Encoding as T
import qualified Data.Aeson as JSON
import qualified Data.Aeson.TH as JSON
import           Data.Unique (newUnique, hashUnique)
import Data.Monoid ((<>))
import Data.Maybe (isNothing)
import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Exception


newtype ClientId = ClientId Int
    deriving (Show, Eq)
newtype GroupId = GroupId Int
    deriving (Show, Eq)
data ClientState = ClientState ClientId ThreadId (Chan Message)
    deriving Eq
data GroupState = GroupState GroupId [ClientState]
    deriving (Eq)
data Message
    = InitGame
        { message :: T.Text
        , clientId :: ClientId
        , allClientIds :: [ClientId]
        }
    | ToPlayers
        { message :: T.Text
        , toIds :: [ClientId]
        }
    | ToAll
        { message :: T.Text
        }
    | EndGame { message :: T.Text }
    deriving (Show, Eq)

getChan :: ClientState -> Chan Message
getChan (ClientState _ _ ch) = ch

getClientState :: ClientId -> [ClientState] -> ClientState
getClientState _ [] = error "Target ClientState not found"
getClientState cid (target@(ClientState cid' _ _) : css)
    | cid == cid' = target
    | otherwise   = getClientState cid css

getClientStates :: GroupState -> [ClientState]
getClientStates (GroupState _ css) = css

getClientId :: ClientState -> ClientId
getClientId (ClientState cid _ _) = cid

getTargetChan :: GroupState -> ClientId -> Chan Message
getTargetChan gs cid = getChan $ getClientState cid $ getClientStates gs

getAllClientIds :: GroupState -> [ClientId]
getAllClientIds (GroupState _ css) = map (\ (ClientState cid' _ _) -> cid') css

JSON.deriveJSON JSON.defaultOptions ''ClientId
JSON.deriveJSON JSON.defaultOptions ''GroupId
JSON.deriveJSON JSON.defaultOptions ''Message

type MatcherChan = Chan (ThreadId, MVar (ClientState, GroupState))
type MatchRequest = (ClientState, MVar (ClientState, GroupState))

------------------------------------------------------------------------------------------

appSocket :: MatcherChan -> WS.ServerApp
appSocket matchCh req = do
    conn <- WS.acceptRequest req
    WS.forkPingThread conn 10
    clientThread conn matchCh

helloApp :: Wai.Application
helloApp req sendResponse = do
    putStrLn $ "Request: " <> show req
    sendResponse $ Wai.responseFile
            Status.status200
            [(Header.hContentType, "text/html; charset=utf-8")]
            "public/index.html"
            Nothing

echo :: WS.Connection -> IO ()
echo conn = go
  where
    go = do
        input :: LBS.ByteString
            <- WS.receiveData conn
        LBC.putStrLn $ input
        WS.sendTextData conn input
        go

------------------------------------------------------------------------------------------

makeMatcherThread :: IO (ThreadId, MatcherChan)
makeMatcherThread = do
    chan <- newChan
    tid <- forkIO $ forever $ match chan
    return (tid, chan)


-- Match clients and make a new group, send it to Client.
-- TODO: Timeout
-- TODO: Request by clients
match :: MatcherChan -> IO ()
match matchCh = do
    let
        groupNum = 2 :: Int

        getMatchRequest :: MatcherChan -> IO MatchRequest
        getMatchRequest mCh = do
            (tid, mv) <- readChan mCh
            cid <- ClientId . hashUnique <$> newUnique
            ch <- newChan
            -- mv is still empty.
            return $ (ClientState cid tid ch, mv)

        makeGroupState :: [MatchRequest] -> IO GroupState
        makeGroupState rqs = do
            gid <- GroupId . hashUnique <$> newUnique
            return $ GroupState gid (map fst rqs)

        -- Just do putMVar.
        sendBackToClient :: GroupState -> [MatchRequest] -> IO ()
        sendBackToClient gs cls = forM_ cls $ \ (cs, mv) -> do
            putMVar mv (cs, gs)

    rqs :: [MatchRequest]
        <- sequence $ take groupNum $ repeat (getMatchRequest matchCh)

    gs :: GroupState
        <- makeGroupState rqs

    sendBackToClient gs rqs

--------------------------------------------------------------------------------

clientThread :: WS.Connection -> MatcherChan -> IO ()
clientThread conn matchCh = do

    let
        close connection = WS.sendClose connection
                $ JSON.encode $ EndGame { message = "Game ended" }

        sendInit connection cs gs = WS.sendTextData connection
                $ JSON.encode $ InitGame
                    { message = "Init Game"
                    , clientId = getClientId cs
                    , allClientIds = getAllClientIds gs
                    }

    tid <- myThreadId
    mv <- newEmptyMVar

    -- Send match request.
    writeChan matchCh (tid, mv)

    -- Wait till match result returns.
    -- TODO: timeout, retry?
    (cs, gs) :: (ClientState, GroupState)
        <- takeMVar mv

    -- Init
    sendInit conn cs gs

    -- Loop
    clientLoop conn cs gs
            `catch` \ (_ :: SomeException) -> close conn

    -- End
    close conn


clientLoop :: WS.Connection -> ClientState -> GroupState -> IO ()
clientLoop conn cs gs = do
    let
        sendMessage :: Chan Message -> Message -> IO ()
        sendMessage ch msg = writeChan ch msg

        -- Get data from client connection, handle the data, and send it to other channels.
        fromClientToChan :: IO ()
        fromClientToChan = do

            input :: LBS.ByteString
                <- WS.receiveData conn

            let
                mmsg = JSON.decode input
                Just msg = mmsg

            when (isNothing mmsg) $ do
                LBC.putStrLn $ "Client sent some data to server, but dencode failed:" <> input
                fromClientToChan

            (cids, msg') :: ([ClientId], Message)
                <- clientProcess cs gs msg

            forM_ cids $ \cid -> do
                sendMessage (getTargetChan gs cid) msg'

            fromClientToChan

        -- Get data from channel, and send it to client with no process.
        fromChanToClient :: Chan Message -> IO ()
        fromChanToClient ch = do
            msg <- readChan ch
            WS.sendTextData conn $ JSON.encode msg
            fromChanToClient ch

    _tid <- forkIO $ fromChanToClient (getChan cs)

    fromClientToChan
        

clientProcess :: ClientState -> GroupState -> Message -> IO ([ClientId], Message)
clientProcess cs gs msg = do
    let
        idsWithoutMyself = filter (/= getClientId cs) (getAllClientIds gs)
    return (idsWithoutMyself, msg)


main :: IO ()
main = do
    let
        port = 3000
        setting = Warp.setPort port Warp.defaultSettings

    putStrLn $ "running port " <> show port <> "..."
    (_tid, matchCh) <- makeMatcherThread

    Warp.runSettings setting
            $ WaiWS.websocketsOr WS.defaultConnectionOptions (appSocket matchCh) helloApp
