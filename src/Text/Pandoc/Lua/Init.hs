{-
Copyright © 2017-2019 Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}
{-# LANGUAGE NoImplicitPrelude #-}
{- |
   Module      : Text.Pandoc.Lua
   Copyright   : Copyright © 2017-2019 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>
   Stability   : alpha

Functions to initialize the Lua interpreter.
-}
module Text.Pandoc.Lua.Init
  ( LuaException (..)
  , LuaPackageParams (..)
  , runLua
  , luaPackageParams
  ) where

import Prelude
import Control.Monad.Trans (MonadIO (..))
import Data.Data (Data, dataTypeConstrs, dataTypeOf, showConstr)
import Foreign.Lua (Lua)
import GHC.IO.Encoding (getForeignEncoding, setForeignEncoding, utf8)
import Text.Pandoc.Class (PandocIO, getCommonState, getUserDataDir,
                          putCommonState)
import Text.Pandoc.Lua.Global (Global (..), setGlobals)
import Text.Pandoc.Lua.Packages (LuaPackageParams (..),
                                 installPandocPackageSearcher)
import Text.Pandoc.Lua.Util (loadScriptFromDataDir)

import qualified Foreign.Lua as Lua
import qualified Foreign.Lua.Module.Text as Lua
import qualified Text.Pandoc.Definition as Pandoc
import qualified Text.Pandoc.Lua.Module.Pandoc as ModulePandoc

-- | Lua error message
newtype LuaException = LuaException String deriving (Show)

-- | Run the lua interpreter, using pandoc's default way of environment
-- initialization.
runLua :: Lua a -> PandocIO (Either LuaException a)
runLua luaOp = do
  luaPkgParams <- luaPackageParams
  globals <- defaultGlobals
  enc <- liftIO $ getForeignEncoding <* setForeignEncoding utf8
  res <- liftIO . Lua.runEither $ do
    setGlobals globals
    initLuaState luaPkgParams
    -- run the given Lua operation
    opResult <- luaOp
    -- get the (possibly modified) state back
    Lua.getglobal "PANDOC_STATE"
    st <- Lua.peek Lua.stackTop
    Lua.pop 1
    -- done
    return (opResult, st)
  liftIO $ setForeignEncoding enc
  case res of
    Left (Lua.Exception msg) -> return $ Left (LuaException msg)
    Right (x, newState) -> do
      putCommonState newState
      return $ Right x

-- | Global variables which should always be set.
defaultGlobals :: PandocIO [Global]
defaultGlobals = do
  commonState <- getCommonState
  return
    [ PANDOC_API_VERSION
    , PANDOC_STATE commonState
    , PANDOC_VERSION
    ]

-- | Generate parameters required to setup pandoc's lua environment.
luaPackageParams :: PandocIO LuaPackageParams
luaPackageParams = do
  datadir <- getUserDataDir
  return LuaPackageParams { luaPkgDataDir = datadir }

-- | Initialize the lua state with all required values
initLuaState :: LuaPackageParams -> Lua ()
initLuaState pkgParams = do
  Lua.openlibs
  Lua.preloadTextModule "text"
  installPandocPackageSearcher pkgParams
  initPandocModule
  loadScriptFromDataDir (luaPkgDataDir pkgParams) "init.lua"
 where
  initPandocModule :: Lua ()
  initPandocModule = do
    -- Push module table
    ModulePandoc.pushModule (luaPkgDataDir pkgParams)
    -- register as loaded module
    Lua.pushvalue Lua.stackTop
    Lua.getfield Lua.registryindex Lua.loadedTableRegistryField
    Lua.setfield (Lua.nthFromTop 2) "pandoc"
    Lua.pop 1
    -- copy constructors into registry
    putConstructorsInRegistry
    -- assign module to global variable
    Lua.setglobal "pandoc"

-- | AST elements are marshaled via normal constructor functions in the
-- @pandoc@ module. However, accessing Lua globals from Haskell is
-- expensive (due to error handling). Accessing the Lua registry is much
-- cheaper, which is why the constructor functions are copied into the
-- Lua registry and called from there.
--
-- This function expects the @pandoc@ module to be at the top of the
-- stack.
putConstructorsInRegistry :: Lua ()
putConstructorsInRegistry = do
  constrsToReg $ Pandoc.Pandoc mempty mempty
  constrsToReg $ Pandoc.Str mempty
  constrsToReg $ Pandoc.Para mempty
  constrsToReg $ Pandoc.Meta mempty
  constrsToReg $ Pandoc.MetaList mempty
  constrsToReg $ Pandoc.Citation mempty mempty mempty Pandoc.AuthorInText 0 0
  putInReg "Attr"  -- used for Attr type alias
  putInReg "ListAttributes"  -- used for ListAttributes type alias
 where
  constrsToReg :: Data a => a -> Lua ()
  constrsToReg = mapM_ (putInReg . showConstr) . dataTypeConstrs . dataTypeOf

  putInReg :: String -> Lua ()
  putInReg name = do
    Lua.push ("pandoc." ++ name) -- name in registry
    Lua.push name -- in pandoc module
    Lua.rawget (Lua.nthFromTop 3)
    Lua.rawset Lua.registryindex
