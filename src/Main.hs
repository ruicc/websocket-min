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
import qualified Data.ByteString as BS
--import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBC
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import qualified Data.Aeson as JSON
import qualified Data.Aeson.TH as JSON
import           Data.Unique (newUnique, hashUnique)
import Data.Monoid ( (<>) )
import Control.Applicative
import Control.Concurrent
import Control.Monad


newtype ClientId = ClientId Int
    deriving (Show, Eq)
newtype GroupId = GroupId Int
    deriving (Show, Eq)
data ClientState = ClientState ClientId ThreadId (Chan Message)
    deriving Eq
data GroupState = GroupState GroupId [ClientState]
    deriving (Eq)
data Message
    = InitGame { clientId :: ClientId, otherClientIds :: [ClientId] }
    | ToAll { message_to_all :: T.Text }
    | EndGame
    deriving (Show, Eq)

JSON.deriveJSON JSON.defaultOptions ''ClientId
JSON.deriveJSON JSON.defaultOptions ''GroupId
JSON.deriveJSON JSON.defaultOptions ''Message

type MatcherChan = Chan (ThreadId, MVar (ClientState, GroupState))
type MatchRequest = (ClientState, MVar (ClientState, GroupState))

------------------------------------------------------------------------------------------

appWebSocketEcho :: WS.ServerApp
appWebSocketEcho req = do
    conn <- WS.acceptRequest req
    void $ WS.forkPingThread conn 10
    void $ echo conn

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
    -- Init
    tid <- myThreadId
    mv <- newEmptyMVar
    writeChan matchCh (tid, mv)

    -- Wait till value returns.
    -- TODO: timeout, retry?
    (cs, gs) :: (ClientState, GroupState)
        <- takeMVar mv

    let
        ClientState (ClientId cid) _ _ = cs

    -- Send clientId
    WS.sendTextData conn $ "{\"msg\":\"Init Game: assign clientId\", \"clientId\":" <> (LBC.pack $ show cid) <> "}"

    -- Loop

    -- End

    WS.sendClose conn $ ("{\"msg\":\"Game ended\"}" :: LBS.ByteString)



main :: IO ()
main = do
    let
        port = 3000
        setting = Warp.setPort port Warp.defaultSettings

    putStrLn $ "running port " <> show port <> "..."
    (_tid, matchCh) <- makeMatcherThread

    Warp.runSettings setting
            $ WaiWS.websocketsOr WS.defaultConnectionOptions (appSocket matchCh) helloApp



-- DONE: Initialize (handshake)
--  とりあえずWebSocketで。
-- TODO: Grouping
--  マッチング系サービスの土台。どうする？
--   * 方針、とりあえず自動でマッチングさせる
--   * Matchingリクエストを投げる、キューに詰める、頭から適当にマッチングさせる、連番付けてMVarで返す
--      スケールしないけどまあ。
--      1threadがChan作って待ち受け、他のthreadがデータ返却用MVarと共にPOSTする
-- TODO: Send message
-- TODO: Create message
