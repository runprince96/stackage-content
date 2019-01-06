#!/usr/bin/env stack
-- stack --resolver lts-12.0 script
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
import Data.Yaml
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import System.Environment (getArgs)
import RIO.Process
import Distribution.Types.PackageId
import qualified RIO.ByteString.Lazy as BL
import qualified Distribution.Text as DT (simpleParse, display)

import Text.HTML.Scalpel.Core
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.HTTP.Simple

comment :: ByteString
comment =
  "# Packages found in the global package database for each GHC version.\n\
  \# Used by post-pantry Stack (merged to master August 2018).\n\
  \# This file auto-generated by update-global-hints.hs.\n\
  \# Please ensure this is updated when a new version of GHC is released.\n\n"

type GhcVer = Text
type PackageId' = Text
type PackageVersion = Text
type GlobalHintsFragment = Map GhcVer (Map PackageId' PackageVersion)

globalHintsFile = "global-hints.yaml"

readGlobalHintsFile :: RIO SimpleApp GlobalHintsFragment
readGlobalHintsFile = do
  -- liftIO $ decodeFileThrow globalHintsFile >>= \v -> error (show (v :: Value))
  eHints <- liftIO $ decodeFileEither globalHintsFile
  case eHints of
    Left e -> do
      logError "Could not open existing global-hints.yaml"
      logError $ displayShow e
      pure mempty
    Right x -> pure x

writeGlobalHintsFile :: GlobalHintsFragment -> RIO SimpleApp ()
writeGlobalHintsFile hints =
  writeFileBinary globalHintsFile $ comment <> encode hints

globalPackageDbHints :: [GhcVer] -> RIO SimpleApp GlobalHintsFragment
globalPackageDbHints vers = do
  pairs <- for vers $ \ghcVer -> do
    let args' =
          [ "--resolver"
          , T.unpack ghcVer
          , "exec"
          , "--no-ghc-package-path"
          , "--"
          , "ghc-pkg"
          , "list"
          , "--global"
          , "--no-user-package-db"
          , "--simple-output"
          ]
    outLBS <- proc "stack" args' readProcessStdout_
    outText <-
      case decodeUtf8' $ BL.toStrict outLBS of
        Left e -> throwIO e
        Right x -> pure x
    pairs <- for (T.words outText) $ \pkgver ->
      case DT.simpleParse $ T.unpack pkgver of
        Nothing -> error $ "Invalid package id: " ++ show pkgver
        Just (PackageIdentifier name ver) ->
          pure (T.pack $ DT.display name, T.pack $ DT.display ver)
    pure (ghcVer, Map.fromList pairs)
  pure $ Map.fromList pairs

scrapeGhcReleaseNotes :: [GhcVer] -> RIO SimpleApp GlobalHintsFragment
scrapeGhcReleaseNotes vers = liftIO $ do
  pairs <- for vers $ \ghcVer -> myScrapeURL ghcVer parser
  pure $ Map.fromList pairs
    where
      url ver = T.unpack $ mconcat
        [ "https://downloads.haskell.org/~ghc/"
        , ver'
        , "/docs/html/users_guide/"
        , ver'
        , "-notes.html"
        ] where ver' = fromMaybe ver (T.stripPrefix "ghc-" ver)
      -- scalpel uses cURL on Windows, yuck
      -- https://stackoverflow.com/q/51936453/388010
      myScrapeURL ghcVer parser = do
        response <- httpBS (fromString (url ghcVer))
        let mversions = scrapeStringLike (decodeUtf8 $ getResponseBody response) parser
        pure (ghcVer, fromMaybe mempty mversions) 
      parser = Map.fromList <$> pairs
      pairs = chroots ("div" @: ["id" @= "included-libraries"] // "tr") $ do
        (pkg:ver:_) <- texts "td"
        pure (pkg, ver)

globalHintsFragmentProviders :: [GhcVer] -> [RIO SimpleApp GlobalHintsFragment]
globalHintsFragmentProviders vers =
  [ globalPackageDbHints vers
  , scrapeGhcReleaseNotes vers
  , readGlobalHintsFile
  ]

-- | Combines fragments point-wise and checks if they agree on common package
-- ids.
combineFragmentList :: [GlobalHintsFragment] -> GlobalHintsFragment
combineFragmentList = foldr combine mempty
  where
    combine = Map.unionWith (Map.unionWithKey combinePoint)
    combinePoint pkg ver1 ver2
      | ver1 == ver2 = ver1
      | otherwise =
          -- ver1 -- If you want to suppress the error below
          error $ concat
            [ "Mismatch between different global-hints fragment providers. "
            , "Check the output of the different providers for package "
            , show (T.unpack pkg)
            , ". Mismatching versions were "
            , show (T.unpack ver1)
            , " and "
            , show (T.unpack ver2)
            , "."
            ]

main :: IO ()
main = runSimpleApp $ do
  args <- liftIO getArgs
  when (null args) $ error "Please provide a list of GHC versions, e.g. ./update-global-hints.hs ghc-8.4.3 ghc-8.4.2"
  let vers = map T.pack args
  hints <- combineFragmentList <$> sequence (globalHintsFragmentProviders vers)
  writeGlobalHintsFile hints