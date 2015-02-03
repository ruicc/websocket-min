{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
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
--import qualified Data.Text as T
--import qualified Data.Text.IO as T
--import qualified Data.Text.Encoding as T
--import qualified Data.Aeson as JSON
import Data.Monoid ( (<>) )
--import Control.Applicative
import Control.Concurrent
import Control.Monad

main :: IO ()
main = do
  let port = 3000
  let setting = Warp.setPort port Warp.defaultSettings
  let app = WaiWS.websocketsOr WS.defaultConnectionOptions appWebSocketEcho helloApp
  putStrLn $ "running port " <> show port <> "..."
  Warp.runSettings setting app

appWebSocketEcho :: WS.ServerApp
appWebSocketEcho req = do
    conn <- WS.acceptRequest req
    void $ spawnPingThread conn 10
    void $ echo conn

spawnPingThread :: WS.Connection -> Int -> IO ThreadId
spawnPingThread conn interval =
    forkIO $ forever $ do
      threadDelay $ 1000 * 1000 * interval
      WS.sendPing conn ("" :: BS.ByteString)

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
