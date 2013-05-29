{-# LANGUAGE TypeFamilies, FlexibleContexts, ScopedTypeVariables #-}
-- | This module is designed to be imported qualified:
--
-- >import qualified Distribution.HaskellSuite.Compiler as Compiler
module Distribution.HaskellSuite.Compiler
  (
  -- * Compiler description
    Is(..)
  , CompileFn

  -- * Simple compiler
  , Simple
  , simple

  -- * Command line
  -- | Compiler's entry point.
  --
  -- It parses command line options (that are typically passed by Cabal) and
  -- invokes the appropriate compiler's methods.
  , main
  )
  where

import Data.Version
import Distribution.HaskellSuite.Packages
import {-# SOURCE #-} Distribution.HaskellSuite.Cabal
import Distribution.Simple.Compiler
import Distribution.Simple.Utils
import Distribution.Verbosity
import Distribution.InstalledPackageInfo
import Distribution.Package
import Distribution.Text
import Distribution.ModuleName (ModuleName)
import Control.Monad
import Control.Exception
import Data.Maybe
import Data.List
import Data.Function
import Language.Haskell.Exts.Annotated.CPP
import Language.Haskell.Exts.Extension

-- | Compilation function
type CompileFn
  =  FilePath -- ^ build directory
  -> Maybe Language -- ^ optional default language
  -> [Extension] -- ^ default extensions
  -> CpphsOptions -- ^ CPP options
  -> PackageDBStack -- ^ package db stack to use
  -> [InstalledPackageId] -- ^ dependencies
  -> [FilePath] -- ^ list of files to compile
  -> IO ()

-- | An abstraction over a Haskell compiler.
--
-- Once you've written a @Compiler.@'Is' instance, you get Cabal
-- integration for free (via @Compiler@.'main').
--
-- Consider whether @Compiler.@'Simple' suits your needs — then you need to
-- write even less code.
--
-- Minimal definition: 'DB', 'name', 'version', 'fileExtensions',
-- 'compile', 'languages', 'languageExtensions'.
--
-- 'fileExtensions' are only used for 'installLib', so if you define
-- a custom 'installLib', 'fileExtensions' won't be used (but you'll still
-- get a compiler warning if you do not define it).
class IsPackageDB (DB compiler) => Is compiler where

  -- | The database type used by the compiler
  type DB compiler

  -- | Compiler's name. Should not contain spaces.
  name :: compiler -> String
  -- | Compiler's version
  version :: compiler -> Version
  -- | File extensions of the files generated by the compiler. Those files
  -- will be copied during the install phase.
  fileExtensions :: compiler -> [String]
  -- | How to compile a set of modules
  compile :: compiler -> CompileFn
  -- | Languages supported by this compiler (such as @Haskell98@,
  -- @Haskell2010@ etc.)
  languages :: compiler -> [Language]
  -- | Extensions supported by this compiler
  languageExtensions :: compiler -> [Extension]

  installLib
      :: compiler
      -> FilePath -- ^ build dir
      -> FilePath -- ^ target dir
      -> Maybe FilePath -- ^ target dir for dynamic libraries
      -> PackageIdentifier
      -> [ModuleName]
      -> IO ()
  installLib t buildDir targetDir _dynlibTargetDir _pkg mods =
    findModuleFiles [buildDir] (fileExtensions t) mods
      >>= installOrdinaryFiles normal targetDir

  -- | Register the package in the database. If a package with the same id
  -- is already installed, it should be replaced by the new one.
  register
    :: compiler
    -> PackageDB
    -> InstalledPackageInfo
    -> IO ()
  register t dbspec pkg = do
    mbDb <- locateDB dbspec

    case mbDb :: Maybe (DB compiler) of
      Nothing -> throwIO RegisterNullDB
      Just db -> do
        pkgs <- readPackageDB (maybeInitDB dbspec) db
        let pkgid = installedPackageId pkg
        writePackageDB db $ pkg : removePackage pkgid pkgs

  -- | Unregister the package
  unregister
    :: compiler
    -> PackageDB
    -> PackageId
    -> IO ()
  unregister t dbspec pkg = do
    let
      pkgCriterion =
        -- if the version is not specified, treat it as a wildcard
        (case pkgVersion $ packageId pkg of
          Version [] _ ->
            ((==) `on` pkgName) pkg
          _ ->
            (==) pkg)
        . sourcePackageId

    mbDb <- locateDB dbspec

    case mbDb :: Maybe (DB compiler) of
      Nothing -> throwIO RegisterNullDB
      Just db -> do
        pkgs <- readPackageDB (maybeInitDB dbspec) db

        let
          (packagesRemoved, packagesLeft) = partition pkgCriterion pkgs

        if null packagesRemoved
          then
            putStrLn $ "No packages removed"
          else do
            putStrLn "Packages removed:"
            forM_ packagesRemoved $ \p ->
              putStrLn $ "  " ++ display (installedPackageId p)

        writePackageDB db packagesLeft

  list
    :: compiler
    -> PackageDB
    -> IO ()
  list t dbspec = do
    mbDb <- locateDB dbspec

    case mbDb :: Maybe (DB compiler) of
      Nothing -> return ()
      Just db -> do
        pkgs <- readPackageDB (maybeInitDB dbspec) db

        forM_ pkgs $ putStrLn . display . installedPackageId

removePackage :: InstalledPackageId -> Packages -> Packages
removePackage pkgid = filter ((pkgid /=) . installedPackageId)

data Simple db = Simple
  { stName :: String
  , stVer :: Version
  , stLangs :: [Language]
  , stLangExts :: [Extension]
  , stCompile :: CompileFn
  , stExts :: [String]
  }

simple
  :: String -- ^ compiler name
  -> Version -- ^ compiler version
  -> [Language]
  -> [Extension]
  -> CompileFn
  -> [String] -- ^ extensions that generated file have
  -> Simple db
simple = Simple

instance IsPackageDB db => Is (Simple db) where
  type DB (Simple db) = db

  name = stName
  version = stVer
  fileExtensions = stExts
  compile = stCompile
  languages = stLangs
  languageExtensions = stLangExts
