{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable,
             TemplateHaskell, ScopedTypeVariables #-}
module Distribution.HaskellSuite.Packages
  (
  -- * Querying package databases
  -- | 'getInstalledPackages' and 'readPackagesInfo' can be used to get
  -- package information from package databases.
  --
  -- They use the 'IsPackageDB' interface, so that you can use them with
  -- your own, custom databases.
  --
  -- Use 'getInstalledPackages' to get all packages defined in a particular
  -- database, and 'readPackagesInfo' when you're searching for
  -- a particular set of packages in a set of databases.
    Packages
  , getInstalledPackages
  , readPackagesInfo
  -- * IsPackageDB class and friends
  , IsPackageDB(..)
  , MaybeInitDB(..)
  -- * StandardDB
  -- | 'StandardDB' is a simple `IsPackageDB` implementation which cover many
  -- (but not all) use cases. Please see the source code to see what
  -- assumptions it makes and whether they hold for your use case.
  , StandardDB(..)
  , IsDBName(..)

  -- * Auxiliary functions
  -- | 'writeDB' and 'readDB' perform (de)serialization of a package
  -- database using a simple JSON encoding. You may use these to implement
  -- 'writePackageDB' and 'readPackageDB' for your own databases.
  , writeDB
  , readDB
  -- * Exceptions
  , PkgDBError(..)
  , PkgInfoError(..)
  )
  where

import Data.Aeson
import Data.Aeson.TH
import Control.Applicative
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as LBS
import Control.Exception as E
import Control.Monad
import Data.Typeable
import Data.Tagged
import Data.Proxy
import qualified Data.Map as Map
import Text.Printf
import Distribution.InstalledPackageInfo
import Distribution.Package
import Distribution.Text
import System.FilePath
import System.Directory

-- The following imports are needed only for generation of JSON instances
import Data.Version (Version(..))
import Distribution.Simple.Compiler (PackageDB(..))
import Distribution.License (License(..))
import Distribution.ModuleName(ModuleName(..))

deriveJSON id ''License
deriveJSON id ''Version
deriveJSON id ''ModuleName
deriveJSON id ''PackageName
deriveJSON id ''PackageIdentifier
deriveJSON id ''InstalledPackageId
deriveJSON id ''InstalledPackageInfo_

--------------
-- Querying --
--------------

type Packages = [InstalledPackageInfo]

-- | Get all packages that are registered in a particular database
getInstalledPackages
  :: forall db. IsPackageDB db
  => MaybeInitDB
  -> Proxy db
  -> PackageDB
  -> IO Packages
getInstalledPackages initDb _proxy dbspec = do
  mbDb <- locateDB dbspec

  maybe
    (return [])
    (readPackageDB initDb)
    (mbDb :: Maybe db)

-- | Try to retrieve an 'InstalledPackageInfo' for each of
-- 'InstalledPackageId's from a specified set of 'PackageDB's.
--
-- May throw a 'PkgInfoNotFound' exception.
readPackagesInfo
  :: IsPackageDB db
  => MaybeInitDB -> Proxy db -> [PackageDB] -> [InstalledPackageId] -> IO Packages
readPackagesInfo initDb proxyDb dbs pkgIds = do
  allPkgInfos <- concat <$> mapM (getInstalledPackages initDb proxyDb) dbs
  let
    pkgMap =
      Map.fromList
        [ (installedPackageId pkgInfo, pkgInfo)
        | pkgInfo <- allPkgInfos
        ]
  forM pkgIds $ \pkgId ->
    maybe
      (throwIO $ PkgInfoNotFound pkgId)
      return
      (Map.lookup pkgId pkgMap)

---------------------------
-- IsPackageDB & friends --
---------------------------

-- | Package database class.
--
-- @db@ will typically be a newtype-wrapped path to the database file,
-- although more sophisticated setups are certainly possible.
  --
  -- Consider using 'StandardDB' first, and implement your own database
  -- type if that isn't enough.
class IsPackageDB db where

  -- | The name of the database. Used to construct some paths.
  dbName :: Tagged db String

  -- | Read a package database.
  --
  -- If the database does not exist, then the first argument tells whether
  -- we should create and initialize it with an empty package list. In
  -- that case, if 'Don'tInitDB' is specified, a 'BadPkgDb' exception is
  -- thrown.
  readPackageDB :: MaybeInitDB -> db -> IO Packages

  -- | Write a package database
  writePackageDB :: db -> Packages -> IO ()

  -- | Get the location of a global package database (if there's one)
  globalDB :: IO (Maybe db)

  -- | Create a db object given a database file path
  dbFromPath :: FilePath -> IO db

  -- Methods that have default implementations

  -- | Convert a package db specification to a db object
  locateDB :: PackageDB -> IO (Maybe db)
  locateDB GlobalPackageDB = globalDB
  locateDB UserPackageDB = Just <$> userDB
  locateDB (SpecificPackageDB p) = Just <$> dbFromPath p

  -- | The user database
  userDB :: IO db
  userDB = do
    let name = untag (dbName :: Tagged db String)
    path <- (</>) <$> haskellPackagesDir <*> pure (name <.> "db")
    dbFromPath path

-- | A flag which tells whether the library should create an empty package
-- database if it doesn't exist yet
data MaybeInitDB = InitDB | Don'tInitDB

----------------
-- StandardDB --
----------------

class IsDBName name where
  getDBName :: Tagged name String

data StandardDB name = StandardDB FilePath

instance IsDBName name => IsPackageDB (StandardDB name) where
  dbName = retag (getDBName :: Tagged name String)

  readPackageDB init (StandardDB db) = readDB init db
  writePackageDB (StandardDB db) = writeDB db
  globalDB = return Nothing
  dbFromPath path = return $ StandardDB path

-------------------------
-- Auxiliary functions --
-------------------------

writeDB :: FilePath -> Packages -> IO ()
writeDB path db = LBS.writeFile path $ encode db

readDB :: MaybeInitDB -> FilePath -> IO Packages
readDB maybeInit path = do
  maybeDoInitDB

  cts <- LBS.fromChunks . return <$> BS.readFile path
    `E.catch` \e ->
      throwIO $ PkgDBReadError path e
  maybe (throwIO $ BadPkgDB path) return $ decode' cts

  where
    maybeDoInitDB
      | InitDB <- maybeInit = do
          dbExists <- doesFileExist path

          unless dbExists $ do
            writeDB path []

      | otherwise = return ()

haskellPackagesDir :: IO FilePath
haskellPackagesDir = getAppUserDataDirectory "haskell-packages"

----------------
-- Exceptions --
----------------

errPrefix :: String
errPrefix = "haskell-suite package manager"

data PkgDBError
  = BadPkgDB FilePath -- ^ package database could not be parsed or contains errors
  | PkgDBReadError FilePath IOException -- ^ package db file could not be read
  | PkgExists InstalledPackageId -- ^ attempt to register an already present package id
  | RegisterNullDB -- ^ attempt to register in the global db when it's not present
  deriving (Typeable)
instance Show PkgDBError where
  show (BadPkgDB path) =
    printf "%s: bad package database at %s" errPrefix path
  show (PkgDBReadError path e) =
    printf "%s: package db at %s could not be read: %s"
      errPrefix path (show e)
  show (PkgExists pkgid) =
    printf "%s: package %s is already in the database" errPrefix (display pkgid)
  show (RegisterNullDB) =
    printf "%s: attempt to register in a null global db" errPrefix
instance Exception PkgDBError

data PkgInfoError
  = PkgInfoNotFound InstalledPackageId
  -- ^ requested package id could not be found in any of the package databases
  deriving Typeable
instance Exception PkgInfoError
instance Show PkgInfoError where
  show (PkgInfoNotFound pkgid) =
    printf "%s: package not found: %s" errPrefix (display pkgid)