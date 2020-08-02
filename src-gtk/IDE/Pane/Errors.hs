{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances,
   MultiParamTypeClasses, DeriveDataTypeable, OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Errors
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  maintainer@leksah.org
-- Stability   :  provisional
-- Portability :
--
-- | A pane which displays a list of errors
--
-----------------------------------------------------------------------------

module IDE.Pane.Errors (
    ErrorsPane
,   ErrorsState
,   fillErrorList
,   getErrors
,   addErrorToList
,   removeErrorsFromList
,   selectMatchingErrors
) where

import Prelude ()
import Prelude.Compat
import Data.Typeable (Typeable)
import IDE.Core.State
       (LogRef(..), IDEM, LogRefType(..), IDEAction, IDERef,
        SrcSpan(..), reflectIDE, liftIDE, logRefFilePath, readIDE,
        errorRefs, collapseErrors, prefs, setCurrentError, logRefFullFilePath)
import IDE.Gtk.State
       (Pane(..), RecoverablePane(..), Connections, PanePath,
        getNotebook, onIDE, Connection(..), postSyncIDE)
import IDE.ImportTool
       (resolveErrors, resolveMenuItems)
import Control.Monad.IO.Class (MonadIO(..))
import IDE.Utils.GUIUtils
       (treeViewContextMenu', __)
import Data.Text (Text)
import Control.Applicative (Alternative(..))
import Control.Monad (filterM, unless, void, when, forever)
import Control.Concurrent (forkIO, threadDelay, MVar, newEmptyMVar, takeMVar, tryPutMVar)
import qualified Data.Text as T
       (dropWhileEnd, unpack, pack, intercalate, lines,
        takeWhile, length, drop)
import Data.IORef (writeIORef, readIORef, newIORef, IORef)
import Data.Maybe (isNothing)
import qualified Data.Foldable as F (toList)
import Data.Char (isSpace)
import Data.Tree (Forest, Tree(..))
import Data.Function.Compat ((&))
import System.Log.Logger (debugM)
import Data.Foldable (forM_)
import GI.Gtk.Objects.Box (boxNew, Box(..))
import GI.Gtk.Objects.ScrolledWindow
       (scrolledWindowSetPolicy, scrolledWindowSetShadowType,
        scrolledWindowNew, ScrolledWindow(..))
import GI.Gtk.Objects.TreeView
       (treeViewScrollToCell, treeViewExpandToPath,
        onTreeViewRowActivated, treeViewGetSelection, treeViewAppendColumn,
        treeViewRowExpanded, setTreeViewHeadersVisible, setTreeViewRulesHint,
        setTreeViewLevelIndentation, treeViewSetModel, treeViewNew,
        TreeView(..))
import GI.Gtk.Objects.ToggleButton
       (toggleButtonGetActive, onToggleButtonToggled,
        toggleButtonNewWithLabel, setToggleButtonActive, ToggleButton(..))
import GI.Gtk.Objects.Widget
       (afterWidgetFocusInEvent, toWidget)
import GI.Gtk.Objects.Notebook (Notebook(..))
import GI.Gtk.Objects.Window (Window(..))
import Graphics.UI.Editor.Parameters (Packing(..), boxPackStart')
import GI.Gtk.Objects.TreeViewColumn
       (TreeViewColumn, TreeViewColumn(..), treeViewColumnSetSizing,
        treeViewColumnNew)
import GI.Gtk.Objects.CellRendererPixbuf
       (setCellRendererPixbufIconName, cellRendererPixbufNew)
import GI.Gtk.Interfaces.CellLayout (cellLayoutPackStart)
import Data.GI.Gtk.ModelView.CellLayout
       (cellLayoutSetDataFunc', cellLayoutSetDataFunction)
import GI.Gtk.Enums
       (PolicyType(..), ShadowType(..), SelectionMode(..),
        TreeViewColumnSizing(..), Orientation(..))
import GI.Gtk.Objects.CellRendererText
       (setCellRendererTextText, cellRendererTextNew)
import GI.Gtk.Interfaces.TreeModel
       (treeModelGetPath)
import Data.GI.Gtk.ModelView.CustomStore (customStoreGetRow)
import GI.Gtk.Objects.TreeSelection
       (treeSelectionSelectPath, treeSelectionUnselectAll,
        treeSelectionSetMode)
import GI.Gtk.Objects.Adjustment (Adjustment)
import GI.Gtk.Objects.Container (containerAdd)
import Control.Monad.Reader (MonadReader(..))
import Data.GI.Gtk.ModelView.ForestStore
       (forestStoreRemove, forestStoreInsert, forestStoreClear,
        forestStoreNew, ForestStore(..),
        forestStoreGetValue, forestStoreGetForest)
import GI.Gtk.Objects.Button (buttonSetLabel)
import GI.Gtk.Structs.TreePath
       (TreePath(..))
import GI.Gtk.Objects.Clipboard (clipboardSetText, clipboardGet)
import GI.Gdk.Structs.Atom (atomIntern)
import Data.Int (Int32)
import Data.GI.Gtk.ModelView.Types
       (treePathNewFromIndices')
import GI.Gtk (getToggleButtonActive)
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import IDE.Utils.DebugUtils (traceTimeTaken)


-- | The representation of the Errors pane
data ErrorsPane      =   ErrorsPane {
    vbox              :: Box
,   scrolledView      :: ScrolledWindow
,   treeView          :: TreeView
,   errorStore        :: ForestStore ErrorRecord
,   autoClose         :: IORef Bool -- ^ If the pane was only displayed to show current error
,   errorsButton      :: ToggleButton
,   warningsButton    :: ToggleButton
,   suggestionsButton :: ToggleButton
,   testFailsButton   :: ToggleButton
,   updateButtons     :: MVar ()
} deriving Typeable


-- | The data for a single row in the Errors pane
data ErrorRecord = ERLogRef LogRef
                 | ERIDE Text
                 | ERFullMessage Text (Maybe LogRef)
    deriving (Eq)

-- | The additional state used when recovering the pane
data ErrorsState = ErrorsState
    {
      showErrors :: Bool
    , showWarnings :: Bool
    , showSuggestions :: Bool
    , showTestFails :: Bool
    }
   deriving (Eq,Ord,Read,Show,Typeable,Generic)

instance ToJSON ErrorsState
instance FromJSON ErrorsState

instance Pane ErrorsPane IDEM
    where
    primPaneName _  =   __ "Errors"
    getTopWidget    =   liftIO . toWidget . vbox
    paneId _b       =   "*Errors"


instance RecoverablePane ErrorsPane ErrorsState IDEM where
    saveState ErrorsPane{..} = do
        showErrors      <- getToggleButtonActive errorsButton
        showWarnings    <- getToggleButtonActive warningsButton
        showSuggestions <- getToggleButtonActive suggestionsButton
        showTestFails   <- getToggleButtonActive testFailsButton
        return (Just ErrorsState{..})

    recoverState pp ErrorsState{..} = do
        nb <- getNotebook pp
        mbErrors <- buildPane pp nb builder
        forM_ mbErrors $ \ErrorsPane{..} -> do
            setToggleButtonActive errorsButton      showErrors
            setToggleButtonActive warningsButton    showWarnings
            setToggleButtonActive suggestionsButton showSuggestions
            setToggleButtonActive testFailsButton   showTestFails
        return mbErrors


    builder = builder'

-- | Builds an 'ErrorsPane' pane together with a list of
--   event 'Connections'
builder' :: PanePath ->
    Notebook ->
    Window ->
    IDEM (Maybe ErrorsPane, Connections)
builder' _pp _nb _windows = do
    ideR <- ask
    errorStore   <- forestStoreNew []

    vbox         <- boxNew OrientationVertical 0

    -- Top box with buttons
    hbox <- boxNew OrientationHorizontal 0
    boxPackStart' vbox hbox PackNatural 0


    errorsButton <- toggleButtonNewWithLabel (__ "Errors")
    warningsButton <- toggleButtonNewWithLabel (__ "Warnings")
    suggestionsButton <- toggleButtonNewWithLabel (__ "Suggestions")
    testFailsButton <- toggleButtonNewWithLabel (__ "Test Failures")
    setToggleButtonActive suggestionsButton False

    forM_ [errorsButton, warningsButton, suggestionsButton, testFailsButton] $ \b -> do
        setToggleButtonActive b True
        boxPackStart' hbox b PackNatural 3
        onToggleButtonToggled b $ reflectIDE (fillErrorList False) ideR

    -- TreeView for bottom part of vbox

    treeView     <- treeViewNew
    treeViewSetModel treeView (Just errorStore)
    setTreeViewLevelIndentation treeView 20
    setTreeViewRulesHint        treeView True
    setTreeViewHeadersVisible   treeView False

    column       <- treeViewColumnNew
    iconRenderer <- cellRendererPixbufNew

    cellLayoutPackStart column iconRenderer False
    cellLayoutSetDataFunction column iconRenderer errorStore
        $ setCellRendererPixbufIconName iconRenderer . toIcon


    treeViewColumnSetSizing column TreeViewColumnSizingAutosize

    renderer <- cellRendererTextNew
    cellLayoutPackStart column renderer False

    cellLayoutSetDataFunc' column renderer errorStore $ \iter -> do
        path <- treeModelGetPath errorStore iter
        row <- customStoreGetRow errorStore iter
        expanded <- treeViewRowExpanded treeView path
        setCellRendererTextText renderer $ toDescription expanded row

    _ <- treeViewAppendColumn treeView column


    selB <- treeViewGetSelection treeView
    treeSelectionSetMode selB SelectionModeMultiple
    scrolledView <- scrolledWindowNew (Nothing :: Maybe Adjustment) (Nothing :: Maybe Adjustment)
    scrolledWindowSetShadowType scrolledView ShadowTypeIn
    containerAdd scrolledView treeView
    scrolledWindowSetPolicy scrolledView PolicyTypeAutomatic PolicyTypeAutomatic
    boxPackStart' vbox scrolledView PackGrow 0

    autoClose <- liftIO $ newIORef False

    updateButtons <- liftIO newEmptyMVar

    let pane = ErrorsPane {..}
    cid1 <- onIDE afterWidgetFocusInEvent treeView $ do
        liftIDE $ makeActive pane
        return True
    cids2 <- treeViewContextMenu' treeView errorStore contextMenuItems
    cid4 <- ConnectC treeView <$> onTreeViewRowActivated treeView (\path col -> do
        record <- forestStoreGetValue errorStore path
        case record of
            ERLogRef _logRef -> errorsSelect ideR errorStore path col
            ERFullMessage _ _ref -> errorsSelect ideR errorStore path col
            _        -> return ())

    fillErrorList' pane
    void . liftIO . forkIO . forever $ do
        takeMVar updateButtons
        reflectIDE (postSyncIDE (doUpdateFilterButtons pane)) ideR
        threadDelay 200000
    return (Just pane, [cid1, cid4] ++ cids2)


toIcon :: ErrorRecord -> Text
toIcon (ERLogRef logRef) =
    case logRefType logRef of
        ErrorRef       -> "ide_error"
        WarningRef     -> "ide_warning"
        LintRef        -> "ide_suggestion"
        TestFailureRef -> "software-update-urgent"
        _              -> ""
toIcon (ERIDE _) = "dialog-error"
toIcon (ERFullMessage _ _) = ""


toDescription :: Bool -> ErrorRecord -> Text
toDescription expanded errorRec =
    case errorRec of
        (ERLogRef logRef)   -> formatExpandableMessage (T.pack $ logRefFilePath logRef) (refDescription logRef)
        (ERIDE msg)         -> formatExpandableMessage "" msg
        (ERFullMessage msg _) -> removeIndentation (cutOffAt 8192 msg)

    where
        formatExpandableMessage location msg
            | expanded  = location
            | otherwise = location <> ": " <> msg & cutOffAt 2048
                                                  & removeIndentation
                                                  & T.lines
                                                  & map removeTrailingWhiteSpace
                                                  & T.intercalate " "


-- | Removes the unnecessary indentation
removeIndentation :: Text -> Text
removeIndentation t = T.intercalate "\n" $ map (T.drop minIndent) l
  where
    l = T.lines t
    minIndent = minimum $ map (T.length . T.takeWhile (== ' ')) l

removeTrailingWhiteSpace :: Text -> Text
removeTrailingWhiteSpace = T.dropWhileEnd isSpace

cutOffAt :: Int -> Text -> Text
cutOffAt n t | T.length t < n = t
             | otherwise      = T.pack (take n (T.unpack t)) <> "..."

-- | Get the Errors pane
getErrors :: Maybe PanePath -> IDEM ErrorsPane
getErrors Nothing    = forceGetPane (Right "*Errors")
getErrors (Just pp)  = forceGetPane (Left pp)

-- | Repopulates the Errors pane
fillErrorList :: Bool -- ^ Whether to display the Errors pane
              -> IDEAction
fillErrorList False = traceTimeTaken "fillErrorList False" $ getPane >>= maybe (return ()) fillErrorList'
fillErrorList True = traceTimeTaken "fillErrorList True" $ getErrors Nothing  >>= \ p -> fillErrorList' p >> displayPane p False

-- | Fills the pane with the error list from the IDE state
fillErrorList' :: ErrorsPane -> IDEAction
fillErrorList' pane = traceTimeTaken "fillErrorList'" $ do
    refs <- F.toList <$> readIDE errorRefs
    visibleRefs <- filterM (isRefVisible pane) refs

    ac   <- liftIO $ readIORef (autoClose pane)
    when (null refs && ac) . void $ closePane pane

    updateFilterButtons pane
    let store = errorStore pane
    let view  = treeView pane
    forestStoreClear store
    forM_ (zip visibleRefs [0..]) $ \(ref, n) -> do
        emptyPath <- treePathNewFromIndices' []
        forestStoreInsert store emptyPath n (ERLogRef ref)
        when (length (T.lines (refDescription ref)) > 1) $ do
            p <- treePathNewFromIndices' [fromIntegral n]
            forestStoreInsert store p 0 (ERFullMessage (refDescription ref) (Just ref))
            collapse <- collapseErrors <$> readIDE prefs
            unless collapse $
                treeViewExpandToPath view =<< treePathNewFromIndices' [fromIntegral n,0]

-- | Returns whether the `LogRef` should be visible in the errors pane
isRefVisible :: MonadIO m => ErrorsPane -> LogRef -> m Bool
isRefVisible pane ref =
    case logRefType ref of
        ErrorRef       -> toggleButtonGetActive (errorsButton pane)
        WarningRef     -> toggleButtonGetActive (warningsButton pane)
        LintRef        -> toggleButtonGetActive (suggestionsButton pane)
        TestFailureRef -> toggleButtonGetActive (testFailsButton pane)
        _              -> return False

-- | Add any LogRef to the Errors pane at a given index
addErrorToList :: Bool -- ^ Whether to display the pane
               -> Int  -- ^ The index to insert at
               -> LogRef
               -> IDEAction
addErrorToList False index lr = getPane >>= maybe (return ()) (addErrorToList' index lr)
addErrorToList True  index lr = getErrors Nothing  >>= \ p -> addErrorToList' index lr p >> displayPane p False

-- | Add a 'LogRef' at a specific index to the Errors pane
addErrorToList' :: Int -> LogRef -> ErrorsPane -> IDEAction
addErrorToList' unfilteredIndex ref pane = traceTimeTaken "addErrorToList'" $ do
    visible <- isRefVisible pane ref
    updateFilterButtons pane
    when visible $ do
        refs <- F.toList <$> readIDE errorRefs
        index <- length <$> filterM (isRefVisible pane) (take unfilteredIndex refs)
        let store = errorStore pane
        let view  = treeView pane
        emptyPath <- treePathNewFromIndices' []
        forestStoreInsert store emptyPath index (ERLogRef ref)
        when (length (T.lines (refDescription ref)) > 1) $ do
            p <- treePathNewFromIndices' [fromIntegral index]
            forestStoreInsert store p 0 (ERFullMessage (refDescription ref) (Just ref))
            collapse <- collapseErrors <$> readIDE prefs
            unless collapse $
                treeViewExpandToPath view =<< treePathNewFromIndices' [fromIntegral index,0]
        when (index == 0) $ do
            path <- treePathNewFromIndices' [0]
            treeViewScrollToCell view (Just path) (Nothing :: Maybe TreeViewColumn) False 0 0

-- | Add any LogRef to the Errors pane at a given index
removeErrorsFromList :: Bool -- ^ Whether to display the pane
                     -> (LogRef -> Bool)
                     -> IDEAction
removeErrorsFromList False toRemove = traceTimeTaken "removeErrorsFromList False" $ getPane >>= maybe (return ()) (removeErrorsFromList' toRemove)
removeErrorsFromList True  toRemove = traceTimeTaken "removeErrorsFromList True" $ getErrors Nothing  >>= \ p -> removeErrorsFromList' toRemove p >> displayPane p False


-- | Add a 'LogRef' at a specific index to the Errors pane
removeErrorsFromList' :: (LogRef -> Bool) -> ErrorsPane -> IDEAction
removeErrorsFromList' toRemove pane = traceTimeTaken "removeErrorsFromList'" $ do
    let store = errorStore pane
    trees <- forestStoreGetForest store
    updateFilterButtons pane
    let refsToRemove = filter (treeToRemove . snd) $ zip [(0::Int32)..] trees
    forM_ (map fst $ reverse refsToRemove) $ \index ->
        forestStoreRemove store =<< treePathNewFromIndices' [index]
  where
    treeToRemove (Node (ERLogRef ref) _) = toRemove ref
    treeToRemove _ = False

updateFilterButtons :: ErrorsPane -> IDEAction
updateFilterButtons pane = void . liftIO $ tryPutMVar (updateButtons pane) ()

-- | Updates the filter buttons in the Error Pane
doUpdateFilterButtons :: ErrorsPane -> IDEAction
doUpdateFilterButtons pane = traceTimeTaken "updateFilterButtons" $ do
    let numRefs refType = length . filter ((== refType) . logRefType) . F.toList <$> readIDE errorRefs
    let setLabel name amount button = buttonSetLabel button (name <> " (" <> T.pack (show amount) <> ")" )

    numErrors      <- numRefs ErrorRef
    numWarnings    <- numRefs WarningRef
    numSuggestions <- numRefs LintRef
    numTestFails   <- numRefs TestFailureRef

    setLabel "Errors"        numErrors      (errorsButton      pane)
    setLabel "Warnings"      numWarnings    (warningsButton    pane)
    setLabel "Suggestions"   numSuggestions (suggestionsButton pane)
    setLabel "Test Failures" numTestFails   (testFailsButton   pane)


---- | Get the currently selected error
--getSelectedError ::  TreeView
--    -> ForestStore ErrorRecord
--    -> IO (Maybe LogRef)
--getSelectedError treeView store = do
--    liftIO $ debugM "leksah" "getSelectedError"
--    treeSelection   <-  treeViewGetSelection treeView
--    paths           <-  treeSelectionGetSelectedRows' treeSelection
--    case paths of
--        path:_ ->  do
--            val     <-  forestStoreGetValue store path
--            case val of
--                ERLogRef logRef -> return (Just logRef)
--                _ -> return Nothing
--        _  ->  return Nothing

-- | Select a 'LogRef' in the Errors pane if it is visible
selectError :: Maybe LogRef -- ^ When @Nothing@, the first row in the list is selected
            -> IDEAction
selectError mbLogRef = do
    liftIO $ debugM "leksah" "selectError"
    (mbPane :: Maybe ErrorsPane) <- getPane
    errors     <- getErrors Nothing
    when (isNothing mbPane) $ do
        liftIO $ writeIORef (autoClose errors) True
        displayPane errors False
    selection <- treeViewGetSelection (treeView errors)
    forest <- forestStoreGetForest (errorStore errors)
    case mbLogRef of
        Nothing -> do
            unless (null forest) $ do
                childPath <- treePathNewFromIndices' [0]
                treeViewScrollToCell (treeView errors) (Just childPath) (Nothing :: Maybe TreeViewColumn) False 0.0 0.0
            treeSelectionUnselectAll selection
        Just lr -> do
            let mbPath = forestFind forest (ERLogRef lr)
            forM_ mbPath $ \path' -> do
                path <- treePathNewFromIndices' path'
                treeViewScrollToCell (treeView errors) (Just path) (Nothing :: Maybe TreeViewColumn) False 0.0 0.0
                treeSelectionSelectPath selection path

    where
        forestFind :: Eq a => Forest a -> a -> Maybe [Int32]
        forestFind = forestFind' [0]
            where
                forestFind' _ [] _ = Nothing
                forestFind' path (Node x trees : forest) y
                    | x == y    = Just path
                    | otherwise = forestFind' (path ++ [0]) trees y
                                      <|> forestFind' (sibling path) forest y

                sibling [n] = [n+1]
                sibling (x:xs) = x:sibling xs
                sibling [] = error "Error in selectError sibling function"

contextMenuItems :: ErrorRecord -> TreePath -> ForestStore ErrorRecord -> IDEM [[(Text, IDEAction)]]
contextMenuItems record _path _store = return
    [("Resolve Errors", resolveErrors) :
        case record of
               ERLogRef logRef -> resolveMenuItems logRef ++ [clipboardItem (refDescription logRef)]
               ERIDE msg       -> [clipboardItem msg]
               _               -> []
    ]
  where
    clipboardItem str = ("Copy message to clipboard",
            atomIntern "CLIBPOARD" False >>= clipboardGet >>= (\c -> clipboardSetText c str (-1)))


-- | Highlight an error refered to by the 'TreePath' in the given 'TreeViewColumn'
errorsSelect :: IDERef
                -> ForestStore ErrorRecord
                -> TreePath
                -> TreeViewColumn
                -> IO ()
errorsSelect ideR store path _ = do
    liftIO $ debugM "leksah" "errorsSelect"
    record <- forestStoreGetValue store path
    case record of
        ERLogRef logRef -> reflectIDE (setCurrentError (Just logRef)) ideR
        ERFullMessage _ (Just ref) -> reflectIDE (setCurrentError (Just ref)) ideR
        _ -> return ()


-- | Select the matching errors for a 'SrcSpan' in the Errors
--   pane, or none at all
selectMatchingErrors :: Maybe SrcSpan -- ^ When @Nothing@, unselects any errors in the pane
                     -> IDEAction
selectMatchingErrors mbSpan = do
    liftIO $ debugM "leksah" "selectMatchingErrors"
    mbErrors <- getPane
    forM_ mbErrors $ \pane -> do
        treeSel <- treeViewGetSelection (treeView pane)
        treeSelectionUnselectAll treeSel
        forM_ mbSpan $ \span' -> do
            _spans <- map logRefSrcSpan . F.toList <$> readIDE errorRefs
            matches <- matchingRefs span' . F.toList <$> readIDE errorRefs
            forM_ matches $ \ref ->
                selectError (Just ref)

matchingRefs :: SrcSpan -> [LogRef] -> [LogRef]
matchingRefs span1 refs =
    -- the path of the SrcSpan in the LogRef absolute, so comparison with the given SrcSpan goes right
    let toAbsolute ref =  ref {logRefSrcSpan = (logRefSrcSpan ref) {srcSpanFilename = logRefFullFilePath ref}}
    in filter (\ref -> filesMatch (logRefSrcSpan (toAbsolute ref)) span1 && span1 `insideOf` logRefSrcSpan (toAbsolute ref)) refs
    where
        filesMatch spanA spanB = srcSpanFilename spanA == srcSpanFilename spanB

        -- Test whether the first span is inside of the second
        insideOf (SrcSpan _ lStart cStart lEnd cEnd) (SrcSpan _ lStart' cStart' lEnd' cEnd')
            =  (lStart, cStart) <= (lEnd', cEnd')
            && (lEnd, cEnd)     >= (lStart', cStart')
