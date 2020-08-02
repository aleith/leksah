{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Workspace
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  maintainer@leksah.org
-- Stability   :  provisional
-- Portability :
--
-- | The pane of the IDE that shows the cabal packages in the workspace
--   and their components, source dependencies and files
--
-----------------------------------------------------------------------------

module IDE.Pane.Workspace (
    WorkspaceState(..)
,   WorkspacePane(..)
,   getWorkspacePane
,   showWorkspacePane
,   redrawWorkspacePane
,   refreshWorkspacePane
,   rebuildWorkspacePane
) where

import Prelude ()
import Prelude.Compat
import Data.Maybe
       (fromJust, fromMaybe, maybeToList, isJust, isNothing)
import Control.Monad (forM, void, when)
import Data.Foldable (forM_, for_)
import Data.Typeable (Typeable)
import Control.Lens ((<&>), (^.), to)
import IDE.Core.State
       (isInterpreting, pjDir, catchIDE,
        MessageLevel(..), ipdPackageId, workspace, readIDE,
        IDEAction, ideMessage, reflectIDE, reifyIDE, IDEM, IDEPackage,
        wsFile, prefs, wsProjects)
import IDE.Pane.SourceBuffer
       (selectSourceBuf, goToSourceDefinition')
import Control.Applicative ((<$>))
import System.FilePath
       (isDrive, (<.>), (</>), takeFileName, dropFileName,
        addTrailingPathSeparator, takeDirectory, takeExtension,
        makeRelative, splitDirectories)
import System.Directory
       (getHomeDirectory, removeDirectoryRecursive,
        createDirectory, doesFileExist, removeFile, doesDirectoryExist,
        getDirectoryContents)
import IDE.Core.CTypes
       (Location(..), packageIdentifierToString)
import Graphics.UI.Frame.Panes
       (RecoverablePane(..), RecoverablePane,
        Pane(..))
import Graphics.UI.Frame.ViewFrame (getMainWindow, getNotebook)
import Graphics.UI.Editor.Basics (Connection(..))
import Control.Monad.IO.Class (MonadIO(..))
import IDE.Utils.GUIUtils
       (showErrorDialog, showInputDialog, treeViewContextMenu',
        __, printf, showConfirmDialog, treeViewToggleRow)
import Control.Exception (SomeException(..), catch)
import Data.Text (Text)
import qualified Data.Text as T (unpack, pack)
import IDE.Core.Types
       (pjLookupPackage, wsLookupProject, pjPackages, activeComponent,
        activePack, activeProject, Project(..), ipdLib, WorkspaceAction,
        runPackage, runProject, pjKey, pjFileOrDir, pjFile,
        runWorkspace, PackageM, ProjectAction, ProjectM,
        IDEPackage(..), Prefs(..), MonadIDE(..), ipdPackageDir,
        nixEnv, ProjectKey(..), CabalProject(..))
import Control.Monad.Reader.Class (MonadReader(..))
import IDE.Workspaces
       (workspaceRemoveProject,
        projectRemovePackage, workspaceActivatePackage, workspaceTryQuiet)
import IDE.Gtk.Workspaces
       (workspaceOpen, makePackage)
import Data.List
       (find, stripPrefix, isPrefixOf, sort)
import Data.Ord (comparing)
import Data.Char (toUpper, toLower)
import System.Log.Logger
       (Priority(..), getLevel, getRootLogger, errorM, debugM)
import Data.Tree (Tree(..))
import IDE.Pane.Modules (addModule)
import IDE.Gtk.Package (packageTest, packageRun, packageClean, packageBench, projectRefreshNix)
import Control.Monad.Trans.Class (MonadTrans(..))
import Data.GI.Gtk.ModelView.ForestStore
       (forestStoreGetTree, forestStoreGetValue, ForestStore(..),
        forestStoreRemove, forestStoreInsert, forestStoreSetValue,
        forestStoreClear, forestStoreNew)
import GI.Gtk.Structs.TreeIter (treeIterCopy, TreeIter(..))
import Data.GI.Gtk.ModelView.TreeModel
       (treeModelIterNext, treeModelIterNthChild, treeModelGetIter,
        treeModelGetPath)
import GI.Gtk.Structs.TreePath
       (TreePath(..))
import GI.Gtk.Objects.ScrolledWindow
       (scrolledWindowSetPolicy, scrolledWindowSetShadowType,
        scrolledWindowNew, ScrolledWindow(..))
import GI.Pango.Structs.FontDescription
       (fontDescriptionFromString)
import GI.Gtk.Objects.TreeView
       (treeViewRowExpanded, onTreeViewRowActivated,
        onTreeViewRowExpanded, treeViewGetSelection,
        treeViewSetHeadersVisible, treeViewAppendColumn, treeViewSetModel,
        treeViewNew, TreeView(..))
import GI.Gtk.Objects.Widget
       (widgetHide, widgetShowAll, toWidget, widgetOverrideFont)
import GI.Gtk.Objects.TreeViewColumn
       (treeViewColumnSetReorderable, treeViewColumnSetResizable,
        treeViewColumnSetSizing, treeViewColumnNew)
import GI.Gtk.Enums
       (PackType(..), Orientation(..), MessageType(..),
        PolicyType(..), ShadowType(..), TreeViewColumnSizing(..))
import GI.Gtk.Objects.CellRendererPixbuf
       (setCellRendererPixbufStockId, cellRendererPixbufNew)
import GI.Gtk.Interfaces.CellLayout (cellLayoutPackStart)
import Data.GI.Gtk.ModelView.CellLayout
       (cellLayoutSetDataFunc')
import GI.Gtk.Objects.CellRendererText
       (setCellRendererTextMarkup, cellRendererTextNew)
import GI.Gtk.Objects.Adjustment (Adjustment)
import GI.Gtk.Objects.Container (containerAdd)
import Data.GI.Gtk.ModelView.CustomStore
       (customStoreGetRow)
import Data.Int (Int32)
import Data.GI.Gtk.ModelView.Types
       (treePathGetIndices', treePathNewFromIndices')
import GI.Gtk.Objects.Box
       (boxSetChildPacking, boxPackStart, boxNew, Box(..))
import GI.Gtk.Objects.LinkButton
       (onLinkButtonActivateLink, linkButtonNewWithLabel, LinkButton(..))
import GI.Gtk (widgetQueueDraw, treeViewExpandRow)
import Criterion.Measurement (getTime, secs)
import Data.Git (isRepo)
import Data.Git.Monad (headGet, withRepo, refNameRaw)
import Data.String (IsString(..))
import Data.Word (Word16)
import qualified GI.Gdk as Gdk (Color(..))
import GI.Gdk
       (setColorGreen, setColorRed, colorToString, setColorBlue)
import Data.GI.Base.Constructible (Constructible(..))
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

-- | The data for a single record in the Workspace Pane
data WorkspaceRecord =
    FileRecord FilePath
  | DirRecord FilePath
              Bool -- Whether it is a source directory
  | ProjectRecord ProjectKey
  | PackageRecord FilePath
  | ComponentsRecord
  | ComponentRecord Text
  | GitRecord
  deriving (Eq, Show)

instance Ord WorkspaceRecord where
    -- | The ordering used for displaying the records
    compare (DirRecord _ _) (FileRecord _) = LT
    compare (FileRecord _) (DirRecord _ _) = GT
    compare (FileRecord p1) (FileRecord p2) = comparing (map toLower) p1 p2
    compare (DirRecord p1 _) (DirRecord p2 _) = comparing (map toLower) p1 p2
    compare (ProjectRecord p1) (ProjectRecord p2) = compare p1 p2
    compare (PackageRecord p1) (PackageRecord p2) = comparing (map toLower) p1 p2
    compare (ComponentRecord t1) (ComponentRecord t2) = comparing (map toLower . T.unpack) t1 t2
    compare _ _ = LT


-- | The markup to show for a record
toMarkup :: WorkspaceRecord
         -> (Maybe Project, Maybe IDEPackage)
         -> IDEM Text
toMarkup record (mbProject, mbPackage) =
    readIDE workspace >>= \case
        Nothing -> return "Error Workspace Closed"
        Just ws -> do
            mbActiveProject   <- readIDE activeProject
            mbActivePackage   <- readIDE activePack
            mbActiveComponent <- readIDE activeComponent

            let worspaceRelative = makeRelative (dropFileName (ws ^. wsFile))
                projectRelative =
                    case mbProject of
                        Just p -> makeRelative . pjDir $ pjKey p
                        Nothing -> id
                activeProject' = (pjKey <$> mbProject) == (pjKey <$> mbActiveProject)
                activePackage = activeProject' && (ipdCabalFile <$> mbPackage) == (ipdCabalFile <$> mbActivePackage)

            case record of
             (ProjectRecord p) -> return $ (if activeProject' then bold else id)
                                        (T.pack . worspaceRelative $ pjFileOrDir p)
             (PackageRecord pFile) -> return $ case mbPackage of
                Nothing -> "Error package not found " <> T.pack pFile
                Just p ->
                    let pkgText = (if activePackage then bold else id)
                                      (packageIdentifierToString (ipdPackageId p))
                        mbLib   = ipdLib p
                        componentText = if activePackage
                                            then maybe (if isJust mbLib then "(library)" else "")
                                                       (\comp -> "(" <> comp <> ")") mbActiveComponent
                                            else ""
                        pkgDir = gray . T.pack . projectRelative $ ipdPackageDir p
                    in (pkgText <> " " <> componentText <> " " <> pkgDir)
             (FileRecord f) -> return $ T.pack $ takeFileName f
             (DirRecord f _)
                 | (ipdPackageDir <$> mbPackage) == Just f -> return "Files"
                 | (pjDir . pjKey <$> mbProject) == Just f -> return "Files"
                 | otherwise -> return $ T.pack $ takeFileName f
             ComponentsRecord -> return "Components"
             (ComponentRecord comp) -> do
                let active = activePackage &&
                                 (isNothing mbActiveComponent && comp == "library"
                                     ||
                                  Just comp == mbActiveComponent)
                return $ (if active then bold else id) comp
             GitRecord ->
                case ipdPackageDir <$> mbPackage of
                    Nothing -> return "No Git repository"
                    Just dir -> liftIO $
                        (findRepoMaybe dir >>= \case
                            Nothing -> return "No Git repository"
                            Just repoPath -> either T.pack id <$>
                                withRepo (fromString repoPath) (
                                    headGet >>= \case
                                        Left sha -> return . T.pack $ show sha
                                        Right name -> return . T.pack $ refNameRaw name))
                         `catch` (\(_ :: SomeException) -> return "No Git branch")
            where
                bold str = "<b>" <> str <> "</b>"
                -- italic str = "<i>" <> str <> "</i>"
                gray str = "<span foreground=\"#999999\">" <> str <> "</span>"

findRepoMaybe :: FilePath -> IO (Maybe FilePath)
findRepoMaybe absoluteDir = do
    homedir <- getHomeDirectory
    let probe dir | isDrive dir || dir == homedir
                  = return Nothing
        probe dir = do
            let gitDir = dir </> ".git"
            isRepo (fromString gitDir) >>= \case
                True -> return $ Just gitDir
                False -> probe $ takeDirectory dir
    probe absoluteDir

timeMarkup
    :: MonadIDE m
    => m Text
    -> m Text
timeMarkup f = do
    start <- liftIO getTime
    markup <- f
    duration <- subtract start <$> liftIO getTime
    liftIO (getLevel <$> getRootLogger) >>= \case
        Just priority | priority < INFO -> do
            dark <- darkUserInterface <$> readIDE prefs
            c <- colorToString =<< colour dark duration
            return $ markup <> " <span foreground=\"" <> c <> "\">" <> T.pack (secs duration) <> "</span>"
        _ -> return markup
  where
    colour True duration | duration < 0.001 = rgb
                                            (round $ 20000 + duration * 1000 * 20000)
                                            (round $ 20000 + duration * 1000 * 20000)
                                            (round $ 20000 + duration * 1000 * 10000)
                         | otherwise = rgb 40000 20000 20000
    colour False duration | duration < 0.00001 = rgb
                                            (round $ 60000 - duration * 1000 * 10000)
                                            (round $ 60000 - duration * 1000 * 10000)
                                            (round $ 60000 - duration * 1000 * 20000)
                         | otherwise = rgb 50000 30000 30000

rgb :: MonadIO m => Word16 -> Word16 -> Word16 -> m Gdk.Color
rgb r g b = do
    c <- new Gdk.Color  []
    setColorRed   c r
    setColorGreen c g
    setColorBlue  c b
    return c

-- | The icon to show for a record
toIcon :: WorkspaceRecord
         -> (Maybe Project, Maybe IDEPackage)
         -> IDEM Text
toIcon record (mbProject, mbPackage) =
    readIDE workspace >>= \case
        Nothing -> return ""
        Just _ws ->
            case record of
                FileRecord path
                    | takeExtension path == ".hs"    -> return "ide_source"
                    | takeExtension path == ".cabal" -> return "ide_cabal_file"
                DirRecord _p isSrc
                    | isSrc     -> return "ide_source_folder"
                    | otherwise -> return "ide_folder"
                ProjectRecord project ->
                    readIDE (to $ nixEnv project "ghc") <&> \case
                        Just _  -> "ide_nix"
                        Nothing -> "ide_source_dependency"
                PackageRecord _pFile -> case (mbProject, mbPackage) of
                    (Just project, Just package) ->
                        isInterpreting (pjKey project, ipdCabalFile package) <&> \case
                                    True  -> "ide_debug"
                                    False -> "ide_package"
                    _ -> return "ide_package"
                ComponentsRecord -> return "ide_component"
                GitRecord        -> return "ide_git"
                _ -> return ""


-- | Gets the package to which a node in the tree belongs
iterToPackage :: ForestStore WorkspaceRecord -> TreeIter -> IDEM (Maybe Project, Maybe IDEPackage)
iterToPackage store iter = do
    path <- treeModelGetPath store iter
    treePathToPackage store path

-- | Gets the package to which a node in the tree belongs
treePathToPackage :: ForestStore WorkspaceRecord -> TreePath -> IDEM (Maybe Project, Maybe IDEPackage)
treePathToPackage store p = treePathGetIndices' p >>= treePathToPackage' store

treePathToPackage' :: ForestStore WorkspaceRecord -> [Int32] -> IDEM (Maybe Project, Maybe IDEPackage)
treePathToPackage' store (n1:n2:_) = do
    projectRecord <- forestStoreGetValue store =<< treePathNewFromIndices' [n1]
    packageRecord <- forestStoreGetValue store =<< treePathNewFromIndices' [n1,n2]
    case (projectRecord, packageRecord) of
        (ProjectRecord pKey, mbPkg) -> readIDE workspace >>= \case
            Just ws -> case wsLookupProject pKey ws of
                Just pj -> case mbPkg of
                    PackageRecord pkgFile -> case pjLookupPackage pkgFile pj of
                        Just pkg -> return (Just pj, Just pkg)
                        _ -> do
                            liftIO . errorM "leksah" $ "treePathToPackage: could not find pakcage " <> pkgFile
                            return (Nothing, Nothing)
                    _ -> return (Just pj, Nothing)
                _ -> do
                    liftIO . errorM "leksah" $ "treePathToPackage: Could not find project " <> show pKey
                    return (Nothing, Nothing)
            _ -> do
                liftIO $ errorM "leksah" "treePathToPackage: No workspace"
                return (Nothing, Nothing)
        _ -> do
            liftIO $ errorM "leksah" "treePathToPackage: Unexpected entry in forest"
            return (Nothing, Nothing)
treePathToPackage' store (n:_) =
    treePathNewFromIndices' [n] >>= forestStoreGetValue store >>= \case
        ProjectRecord pKey -> readIDE workspace >>= \case
            Just ws -> case wsLookupProject pKey ws of
                Just pj -> return (Just pj, Nothing)
                _ -> do
                    liftIO . errorM "leksah" $ "treePathToPackage: Could not find project " <> show pKey
                    return (Nothing, Nothing)
            _ -> do
                liftIO $ errorM "leksah" "treePathToPackage: No workspace"
                return (Nothing, Nothing)
        _                     -> do
            liftIO $ debugM "leksah" "treePathToPackage: Unexpected entry at root forest"
            return (Nothing, Nothing)
treePathToPackage' _ _ = do
    liftIO $ debugM "leksah" "treePathToPackage is called with empty path"
    return (Nothing, Nothing)


-- | Determines whether the 'WorkspaceRecord' can expand, i.e. whether
-- it should get an expander.
canExpand :: WorkspaceRecord -> Project -> Maybe IDEPackage -> IDEM Bool
canExpand record pj mbPkg = case record of
    (ProjectRecord _) -> return False
    (PackageRecord _) -> return True
    (DirRecord fp _)     -> do
        mbWs <- readIDE workspace
        case mbWs of
            Just ws -> not . null <$> ((`runWorkspace` ws) . (`runProject` pj) $ dirRecords fp mbPkg)
            Nothing -> return False
    ComponentsRecord    -> return . not . null $ components
    _                   -> return False

    where components = maybeToList (ipdLib pkg)
                ++ ipdSubLibraries pkg
                ++ ipdExes pkg
                ++ ipdTests pkg
                ++ ipdBenchmarks pkg
          pkg = fromJust mbPkg -- Only for record trypes that should have a package (not ProjectRecord)

-- * The Workspace pane

-- | The representation of the Workspace pane
data WorkspacePane        =   WorkspacePane {
    box             ::   Box
,   scrolledView    ::   ScrolledWindow
,   noWsText        ::   LinkButton
,   treeView        ::   TreeView
,   recordStore     ::   ForestStore WorkspaceRecord
} deriving Typeable


-- | The additional state used when recovering the pane
--   (none)
data WorkspaceState = WorkspaceState
    deriving(Eq,Ord,Read,Show,Typeable,Generic)

instance ToJSON WorkspaceState
instance FromJSON WorkspaceState

instance Pane WorkspacePane IDEM where
    primPaneName _  =   __ "Workspace"
    getAddedIndex _ =   0
    getTopWidget    =   liftIO . toWidget . box
    paneId _        =   "*Workspace"

instance RecoverablePane WorkspacePane WorkspaceState IDEM where
    saveState _     =   return (Just WorkspaceState)

    recoverState pp WorkspaceState =   do
        nb      <-  getNotebook pp
        buildPane pp nb builder

    builder _pp _nb _windows = do
        ideR        <- ask
        recordStore <-  forestStoreNew []

        -- Treeview
        treeView    <- buildTreeView recordStore
        sigIds      <- treeViewEvents recordStore treeView

        -- Scrolled view
        scrolledView <- scrolledWindowNew (Nothing :: Maybe Adjustment) (Nothing :: Maybe Adjustment)
        scrolledWindowSetShadowType scrolledView ShadowTypeIn
        scrolledWindowSetPolicy scrolledView PolicyTypeAutomatic PolicyTypeAutomatic
        containerAdd scrolledView treeView

        -- "Open workspace" link
        noWsText <- linkButtonNewWithLabel "Open a workspace" (Just "Open a workspace")
        _ <- onLinkButtonActivateLink noWsText $ do
            reflectIDE workspaceOpen ideR
            return False

        -- Box, top-level widget of the pane
        box <- boxNew OrientationVertical 0
        boxPackStart box scrolledView False True 0
        boxPackStart box noWsText True True 0
        -- Calling refreshWorkspacePane here does not work
        -- since the GUI is not yet running. This created strange behaviour
        -- where the workspace was split evenly while only one of the
        -- widgets (ScrolledView/TreeView and Openworkspace link).
        -- Instead we initialize the packing of the TreeView to not expand
        -- and rely on the fact that refreshWorkspacePane is called
        -- by the WorkspaceChanged event, and the packing of the two
        -- widgets is changed there when swapping.


        let wsPane = WorkspacePane {..}

        return (Just wsPane, sigIds)


buildTreeView :: ForestStore WorkspaceRecord -> IDEM TreeView
buildTreeView recordStore = do
        treeView    <-  treeViewNew
        treeViewSetModel treeView (Just recordStore)

        col1        <- treeViewColumnNew
        treeViewColumnSetSizing col1 TreeViewColumnSizingAutosize
        treeViewColumnSetResizable col1 True
        treeViewColumnSetReorderable col1 True
        _ <- treeViewAppendColumn treeView col1

        ideR <- ask
        prefs' <- readIDE prefs
        when (showWorkspaceIcons prefs') $ do
            renderer2    <- cellRendererPixbufNew
            cellLayoutPackStart col1 renderer2 False
            setCellRendererPixbufStockId renderer2 ""
            cellLayoutSetDataFunc' col1 renderer2 recordStore $ \iter -> do
                record <- customStoreGetRow recordStore iter
                projAndPkg <- (`reflectIDE` ideR) $ iterToPackage recordStore iter
                icon <- (`reflectIDE` ideR) $ toIcon record projAndPkg
                setCellRendererPixbufStockId renderer2 icon

        renderer1    <- cellRendererTextNew
        cellLayoutPackStart col1 renderer1 True
        cellLayoutSetDataFunc' col1 renderer1 recordStore $ \iter -> do
            record <- customStoreGetRow recordStore iter
            projAndPkg <- (`reflectIDE` ideR) $ iterToPackage recordStore iter
            -- The cellrenderer is stateful, so it knows which cell this markup will be for (the cell at iter)
            markup <- (`reflectIDE` ideR) . timeMarkup $ toMarkup record projAndPkg
            setCellRendererTextMarkup renderer1 markup

        -- set workspace font
        mbFd <- case workspaceFont prefs' of
            (True, Just str) ->  Just <$> fontDescriptionFromString str
            _ -> return Nothing
        widgetOverrideFont treeView mbFd

         -- treeViewSetActiveOnSingleClick treeView True
        treeViewSetHeadersVisible treeView False
        _sel <- treeViewGetSelection treeView
        -- treeSelectionSetMode sel SelectionModeSingle

        return treeView


treeViewEvents :: ForestStore WorkspaceRecord -> TreeView -> IDEM [Connection]
treeViewEvents recordStore treeView = do
    ideR <- ask
    cid1 <- onTreeViewRowExpanded treeView $ \iter path -> do
        _record <- forestStoreGetValue recordStore path
        (`reflectIDE` ideR) $ iterToPackage recordStore iter >>= \case
            (Just project, _) ->
                workspaceTryQuiet . (`runProject` project) $
                    refreshPackageTreeFrom recordStore treeView path
            _ -> return ()

    cid2 <- onTreeViewRowActivated treeView $ \path _col -> do
        record <- forestStoreGetValue recordStore path
        (`reflectIDE` ideR) $ treePathToPackage recordStore path >>= \case
            (Just project, mbPkg) -> do
                expandable <- canExpand record project mbPkg
                case record of
                        ProjectRecord project' -> mapM_ selectSourceBuf $ pjFile project'
                        FileRecord f  -> void $ goToSourceDefinition' f (Location "" 1 0 1 0)
                        ComponentRecord name -> workspaceTryQuiet $
                                                          workspaceActivatePackage project mbPkg (Just name)
                        _ -> when expandable $
                                 void $ treeViewToggleRow treeView path
            _ -> return ()

    sigIds <- treeViewContextMenu' treeView recordStore $ contextMenuItems treeView
    return $ sigIds <> map (ConnectC treeView) [cid1, cid2]


-- | Get the Workspace pane
getWorkspacePane :: IDEM WorkspacePane
getWorkspacePane = forceGetPane (Right "*Workspace")


-- | Show the Workspace pane
showWorkspacePane :: IDEAction
showWorkspacePane = do
    l <- getWorkspacePane
    displayPane l False


-- | Deletes the Workspace pane and rebuilds it (used when enabling/disabling
-- icons, since it requires extra/fewer cellrenderers)
rebuildWorkspacePane :: IDEAction
rebuildWorkspacePane = do
    mbWsPane <- getPane :: IDEM (Maybe WorkspacePane)
    forM_ mbWsPane closePane
    void (getOrBuildPane (Right "*Workspace") :: IDEM (Maybe WorkspacePane))


---- | Searches the workspace packages if it is part of any of them
--fileGetPackage :: FilePath -> WorkspaceM (Maybe IDEPackage)
--fileGetPackage path = do
--    packages <- view wsAllPackages <$> ask
--    let dirs     = [p | p <- packages, takeDirectory (ipdCabalFile p) `isPrefixOf` path]
--    return (listToMaybe dirs)



-- * Actions for refreshing the Workspace pane

redrawWorkspacePane :: IDEAction
redrawWorkspacePane = do
    liftIO $ debugM "leksah" "redrawWorkspacePane"
    w <- getWorkspacePane
    widgetQueueDraw $ treeView w


-- | Refreshes the Workspace pane, lists all packages and synchronizes the expanded
-- nodes with the file system and workspace
refreshWorkspacePane :: IDEAction
refreshWorkspacePane = do
    liftIO $ debugM "leksah" "refreshWorkspacePane"
    ws <- getWorkspacePane
    refresh ws


-- | Seperately defined from refreshWorkspacePane, since getWorkspacePane does not
-- work before the building is finished
refresh :: WorkspacePane -> IDEAction
refresh WorkspacePane{..} =
    -- Depending on if there is a workspace, show the tree or a message to open one
    readIDE workspace >>= \case

        Nothing -> do
            widgetHide scrolledView
            boxSetChildPacking box scrolledView False False 0 PackTypeStart
            widgetShowAll noWsText
            boxSetChildPacking box noWsText True True 0 PackTypeStart

        Just ws -> do
            widgetHide noWsText
            boxSetChildPacking box noWsText False False 0 PackTypeStart
            widgetShowAll scrolledView
            boxSetChildPacking box scrolledView True True 0 PackTypeStart
            let projects = ws ^. wsProjects
            forestStoreClear recordStore
            (`runWorkspace` ws) $ do
                path <- liftIO $ treePathNewFromIndices' []
                for_ (zip [0..] projects) $ \(n, project) -> do
                    let projectRecord = ProjectRecord $ pjKey project
                    liftIO $ debugM "leksah" $ show $ pjKey project
                    liftIO $ forestStoreInsert recordStore path n projectRecord
                    (`runProject` project) $ do
                        path' <- liftIO $ treePathNewFromIndices' [fromIntegral n]
                        projectChildren <- children projectRecord Nothing
                        lift $ setChildren (Just project) Nothing recordStore treeView [fromIntegral n] projectChildren
                        treeViewExpandRow treeView path' False


-- | Mutates the 'ForestStore' with the given TreePath as root to attach new
-- entries to. Walks the directory tree recursively when refreshing directories.
refreshPackageTreeFrom :: ForestStore WorkspaceRecord -> TreeView -> TreePath -> ProjectAction
refreshPackageTreeFrom store view' path = do
    record     <- liftIO $ forestStoreGetValue store path
    (Just project, mbPkg) <- liftIDE $ treePathToPackage store path
    -- expandable <- liftIDE $ canExpand record project mbPkg

    kids     <- children record mbPkg
    path' <- treePathGetIndices' path
    lift $ setChildren (Just project) mbPkg store view' path' kids

-- | Returns the children of the 'WorkspaceRecord'.
children :: WorkspaceRecord -> Maybe IDEPackage -> ProjectM [WorkspaceRecord]
children record mbPkg = case record of
    DirRecord dir _     -> dirRecords dir mbPkg
    ComponentsRecord    -> runPkg componentsRecords
    ProjectRecord project -> (<> [DirRecord (pjDir project) False]) <$>
        (readIDE workspace >>= \case
            Nothing -> return []
            Just ws -> return $ maybe [] (map (PackageRecord . ipdCabalFile) . pjPackages)
                                    $ wsLookupProject project ws)
    PackageRecord pkg   ->
        return [ ComponentsRecord
               , GitRecord
               , DirRecord (dropFileName pkg) False]
    _                   -> return []
  where
    runPkg = (`runPackage` fromJust mbPkg)

-- | Returns the contents at the given 'FilePath' as 'WorkspaceRecord's.
-- Runs in the PackageM monad to determine if directories are
-- source directories (as specified in the cabal file)
dirRecords :: FilePath -> Maybe IDEPackage -> ProjectM [WorkspaceRecord]
dirRecords dir mbPkg = do
   prefs'   <- readIDE prefs
   contents <- liftIO $ getDirectoryContents dir
                            `catch` \(_ :: IOError) -> return []
   let filtered = if showHiddenFiles prefs'
                      then filter (`notElem` [".", ".."]) contents
                      else filter (not . isPrefixOf ".") contents
   records <- forM filtered $ \f -> do
                  let full = dir </> f
                  isDir <- liftIO $ doesDirectoryExist full
                  if isDir
                      then case mbPkg of
                        Just pkg -> do
                          -- find out if it is a source directory of the project
                          let pkgDir = addTrailingPathSeparator . takeDirectory $ ipdCabalFile pkg
                          case stripPrefix pkgDir full of
                              Just relativeToPackage -> do
                                  let srcDirs = ipdSrcDirs pkg
                                  return $ DirRecord full (relativeToPackage `elem` srcDirs)
                              Nothing ->
                                  -- It's not a descendant of the package directory (e.g. in a source dependency)
                                  return $ DirRecord full False
                        Nothing -> return $ DirRecord full False
                      else return $ FileRecord full
   return (sort records)


-- | Get the components for a specific package
componentsRecords :: PackageM [WorkspaceRecord]
componentsRecords = sort . map ComponentRecord . components <$> ask
    where
        components package = map ("lib:"<>) (maybeToList (ipdLib package))
                          ++ map ("lib:"<>) (ipdSubLibraries package)
                          ++ map ("exe:"<>) (ipdExes package)
                          ++ map ("test:"<>) (ipdTests package)
                          ++ map ("bench:"<>) (ipdBenchmarks package)

-- | Recursively sets the children of the given 'TreePath' to the provided tree of 'WorkspaceRecord's. If a record
-- is already present, it is kept in the same (expanded) state.
-- If a the parent record is not expanded just makes sure at least one of
-- the children is added.
setChildren :: Maybe Project
            -> Maybe IDEPackage
            -> ForestStore WorkspaceRecord
            -> TreeView
            -> [Int32]
            -> [WorkspaceRecord] -> WorkspaceAction
setChildren _ _ store _ [] [] = liftIO $ forestStoreClear store
setChildren mbProject mbPkg store view parentPath kids = do
    ws <- ask
    -- We only need to get all the children right when they are visible
    expanded <- if null parentPath
                    then return True
                    else liftIO $ treeViewRowExpanded view =<< treePathNewFromIndices' parentPath
    let kidsToAdd = (if expanded
                            then id
                            else take 1) kids

    forM_ (zip [0..] kidsToAdd) $ \(n, record) -> do
      liftIO $ do
        debugM "leksah" $ "setChildren " <> show parentPath
        mbChildIter <- (treeModelGetIter store =<< treePathNewFromIndices' parentPath) >>= \case
            Just parentIter ->
                treeModelIterNthChild store (Just parentIter) n >>= \case
                    (True, childIter) -> return (Just childIter)
                    (False, _)        -> return Nothing
            Nothing         -> return Nothing
        let compareRec rec1 rec2 = case (rec1, rec2) of
                (ProjectRecord p1, ProjectRecord p2) -> p1 == p2
                (PackageRecord p1, PackageRecord p2) -> p1 == p2
                _ -> rec1 == rec2
        findResult <- searchToRight compareRec record store mbChildIter
        case (mbChildIter, findResult) of
            (_, WhereExpected iter) -> do -- it's already there
                path <- treeModelGetPath store iter
                forestStoreSetValue store path record
            (Just iter, Found _) -> do -- it's already there at a later sibling
                path <- treeModelGetPath store iter
                removeUntil record store path
            _ -> do
                parentPath' <- treePathNewFromIndices' parentPath
                forestStoreInsert store parentPath' (fromIntegral n) record
      let project = case record of
                        ProjectRecord p -> fromJust $ wsLookupProject p ws
                        _               -> fromJust mbProject
          mbPkg' = case record of
                        PackageRecord p -> pjLookupPackage p project
                        _               -> mbPkg
      -- Only update the grand kids if they are visible
      when expanded $ do
          grandKids <- (`runProject` project) $ children record mbPkg'
          setChildren (Just project) mbPkg' store view (parentPath ++ [n]) grandKids

    liftIO $ if null kids
        then forestStoreRemoveChildren store parentPath
        else when expanded . void $ removeRemaining store =<< treePathNewFromIndices' (parentPath++[fromIntegral $ length kids])


-- * Context menu

contextMenuItems :: TreeView -> WorkspaceRecord -> TreePath -> ForestStore WorkspaceRecord -> IDEM [[(Text, IDEAction)]]
contextMenuItems view record path store = do
    mainWindow <- getMainWindow
    let refreshTree p =
            treePathToPackage store p >>= \case
                (Just project, _) -> workspaceTryQuiet . (`runProject` project) $
                    refreshPackageTreeFrom store view p
                _ -> refreshWorkspacePane

    parentPath <- treePathNewFromIndices' =<< (reverse . drop 1 . reverse <$> treePathGetIndices' path)

    case record of
        (FileRecord fp) -> do
            let onDeleteFile = flip catchIDE (\(e :: SomeException) -> ideMessage High . T.pack $ show e) $ reifyIDE $ \ideRef -> do
                    isConfirmed <- showConfirmDialog (Just mainWindow) True (__ "Delete File") $
                        T.pack $ printf "Are you sure you want to delete %s?" (takeFileName fp)
                        ("Are you sure you want to delete " <> T.pack (takeFileName fp) <> "?")
                    when isConfirmed $ do
                        removeFile fp
                        reflectIDE (refreshTree parentPath) ideRef

            return [[(__ "Open File...", void $ goToSourceDefinition' fp (Location "" 1 0 1 0))]
                   ,[(__ "Delete File...", onDeleteFile)]]

        DirRecord fp _ -> do

            let onNewModule = flip catchIDE (\(e :: SomeException) -> ideMessage High . T.pack $ show e) $
                    treePathToPackage store path >>= \case
                        (Just project, Just pkg) ->
                            workspaceTryQuiet . (`runProject` project) . (`runPackage` pkg) $ do
                                mbModulePath <- dirToModulePath fp
                                let modulePrefix = fromMaybe [] mbModulePath
                                addModule modulePrefix
                                packagePath <- treePathNewFromIndices' =<< (take 2 <$> treePathGetIndices' path)
                                lift $ refreshPackageTreeFrom store view packagePath
                        _ -> return ()

            let onNewTextFile = flip catchIDE (\(e :: SomeException) -> ideMessage High . T.pack $ show e) $ reifyIDE $ \ideRef -> do
                    mbText <- showInputDialog (Just mainWindow) "File name:" ""
                    case mbText of
                        Just t  -> do
                            let filepath = fp </> T.unpack t
                            exists <- doesFileExist filepath
                            if exists
                                then showErrorDialog (Just mainWindow) "File already exists"
                                else do
                                    writeFile filepath ""
                                    void $ reflectIDE (refreshTree path >> goToSourceDefinition' filepath (Location "" 1 0 1 0)) ideRef
                        Nothing -> return ()

            let onNewDir = flip catchIDE (\(e :: SomeException) -> ideMessage High . T.pack $ show e) $ reifyIDE $ \ideRef -> do
                    mbText <- showInputDialog (Just mainWindow) "Directory name:" ""
                    case mbText of
                        Just t  -> do
                            let filepath = fp </> T.unpack t
                            exists <- doesDirectoryExist filepath
                            if exists
                                then showErrorDialog (Just mainWindow) "Directory already exists"
                                else do
                                    createDirectory filepath
                                    void $ reflectIDE (refreshTree path) ideRef
                        Nothing -> return ()

            let onDeleteDir = flip catchIDE (\(e :: SomeException) -> ideMessage High . T.pack $ show e) $ reifyIDE $ \ideRef -> do
                    isConfirmed <- showConfirmDialog (Just mainWindow) True (__ "Delete directory") $
                        T.pack $ printf "Are you sure you want to delete %?" (takeFileName fp)
                    when isConfirmed $ do
                        removeDirectoryRecursive fp
                        reflectIDE (refreshTree parentPath) ideRef

            return [ [ ("New Module...", onNewModule)
                     , ("New Text File...", onNewTextFile)
                     , ("New Directory...", onNewDir)
                     ]
                   , [ ("Delete Directory...", onDeleteDir)
                     ]
                   ]

        ProjectRecord projectKey -> do
            let onSetActive = workspaceTryQuiet $ do
                    ws <- ask
                    case wsLookupProject projectKey ws of
                        Just project -> workspaceActivatePackage project Nothing Nothing
                        Nothing -> liftIO . errorM "leksah" $ "onSetActive: Project not found " <> show projectKey
                onRefreshNix = workspaceTryQuiet $ do
                    ws <- ask
                    case wsLookupProject projectKey ws of
                        Just project -> runProject projectRefreshNix project
                        Nothing -> liftIO . errorM "leksah" $ "onSetActive: Project not found " <> show projectKey
                onOpenProjectFile = mapM_ selectSourceBuf $ pjFile projectKey
                onOpenProjectConfigurationFile =
                    case projectKey of
                        CabalTool p -> void $ selectSourceBuf $ pjCabalFile p <.> "local"
                        _ -> return ()
                onRemoveFromWs = workspaceTryQuiet $ do
                    workspaceRemoveProject projectKey
                    liftIDE refreshWorkspacePane

            return [ [ ("Set As Active Project", onSetActive)
                     , ("Open Project File", onOpenProjectFile)
                     , ("Open Project Configuration File", onOpenProjectConfigurationFile)
                     , ("Refresh Nix Environment Varialbes", onRefreshNix)
                     ]
                   , [
                     ("Remove From Workspace", onRemoveFromWs)
                     ]
                   ]

        PackageRecord _ ->
            treePathToPackage store path >>= \case
                (Just project, Just p) -> do

                    let runPkg = (`runProject` project) . (`runPackage` p)
                        onSetActive = workspaceTryQuiet $ workspaceActivatePackage project (Just p) Nothing
                        onAddModule = workspaceTryQuiet $ runPkg $ addModule []
                        onOpenCabalFile = void . selectSourceBuf $ ipdCabalFile p
                        onRemoveFromProject = workspaceTryQuiet . (`runProject` project) $ do
                            projectRemovePackage p
                            liftIDE refreshWorkspacePane

                    return [ [ ("New Module...", onAddModule)
                             , ("Set As Active Package", onSetActive)

                             ]
                           , [ ("Build", workspaceTryQuiet $ runPkg makePackage)
                             , ("Run", workspaceTryQuiet $ runPkg packageRun)
                             , ("Test", workspaceTryQuiet $ runPkg packageTest)
                             , ("Benchmark", workspaceTryQuiet $ runPkg packageBench)
                             , ("Clean", workspaceTryQuiet $ runPkg packageClean)
                             , ("Open Package File", onOpenCabalFile)
                             ]
                           , [
                             ("Remove From Project", onRemoveFromProject)
                             ]
                           ]
                _ -> return []

        ComponentRecord comp -> do
            (Just project, Just pkg) <- treePathToPackage store path
            let onSetActive = workspaceTryQuiet $
                                  workspaceActivatePackage project (Just pkg) (Just comp)
            return [[ ("Activate component", onSetActive) ]]

        _ -> return []


-- | Searches the source folders to determine what the corresponding
--   module path is
dirToModulePath :: FilePath -> PackageM (Maybe [Text])
dirToModulePath fp = do
    pkgDir <- ipdPackageDir <$> ask
    srcDirs <- map (pkgDir <>) . ipdSrcDirs <$> ask
    return $ do
        srcDir <- find (`isPrefixOf` fp) srcDirs
        let suffix = if srcDir == fp then "" else makeRelative srcDir fp
        let dirs   = map (T.pack . capitalize) (splitDirectories suffix)
        return dirs
    where
        capitalize (x:xs) = toUpper x : xs
        capitalize [] = []


-- * Utility functions for operating on 'ForestStore'

forestStoreRemoveChildren :: ForestStore a -> [Int32] -> IO ()
forestStoreRemoveChildren store path = do
    Node _record children' <- forestStoreGetTree store =<< treePathNewFromIndices' path
    forM_ (zip [(0::Integer)..] children') $ \_ ->
        forestStoreRemove store =<< treePathNewFromIndices' (path ++ [0]) -- this works because mutation ...

data FindResult = WhereExpected TreeIter | Found TreeIter | NotFound

-- | Tries to find the given value in the 'ForestStore'. Only looks at the given 'TreeIter' and its
-- sibling nodes to the right.
-- Returns @WhereExpected iter@ if the records is found at the provided 'TreeIter'
-- Returns @Found iter@ if the record is found at a sibling iter
-- Returns @NotFound@ otherwise
searchToRight :: (a -> a -> Bool) -> a -> ForestStore a -> Maybe TreeIter -> IO FindResult
searchToRight _ _ _ Nothing = return NotFound
searchToRight comp a store (Just iter) = do
    row <- customStoreGetRow store iter
    if comp row a
        then return $ WhereExpected iter
        else do
            next <- treeIterCopy iter
            treeModelIterNext store next >>= find' next
  where
    find' :: TreeIter -> Bool -> IO FindResult
    find' _ False = return NotFound
    find' iter' True = do
        row <- customStoreGetRow store iter'
        if comp row a
            then return $ Found iter'
            else do
                next <- treeIterCopy iter'
                treeModelIterNext store next >>= find' next


-- | Starting at the node at the given 'TreePath', removes all sibling nodes to the right
--   until the given value is found.
removeUntil :: Eq a => a -> ForestStore a -> TreePath -> IO ()
removeUntil a store path = do
    row <- forestStoreGetValue store path
    when (row /= a) $ do
        found <- forestStoreRemove store path
        when found $ removeUntil a store path


-- | Starting at the node at the given 'TreePath', removes all sibling nodes to the right
removeRemaining :: ForestStore a -> TreePath -> IO ()
removeRemaining store path = do
    found <- forestStoreRemove store path
    when found $ removeRemaining store path
