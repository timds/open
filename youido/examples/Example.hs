{-# LANGUAGE OverloadedStrings, ExistentialQuantification, ScopedTypeVariables,
   ExtendedDefaultRules, FlexibleContexts, TemplateHaskell,
   OverloadedLabels, TypeOperators, DataKinds, DeriveGeneric #-}

import Youido.Serve
import Youido.Types
import Youido.Dashdo
import Lucid
import Lucid.Bootstrap
import Lucid.Rdash
import Numeric.Datasets.Gapminder
import Numeric.Datasets
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import Data.List (nub)
import Network.Wai
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import Data.Monoid
import Lens.Micro.Platform
--import Graphics.Plotly.Lucid.hs

import Dashdo.Elements
import Dashdo.FlexibleInput
import Dashdo.Types
import Data.Proxy
import GHC.Generics
import Text.Digestive.View (View)
import qualified Data.Text.IO as TIO

data TodoR = ListTodos
           | EditTodoList
           | UpdateTodoList (Form TodoList)
  deriving (Show, Generic)

instance FromRequest TodoR
instance ToURL TodoR

data TodoList = TodoList { title :: Text, items :: [Todo], category :: Text }
  deriving (Show, Generic)

instance FromForm TodoList

data TodoTag = TodoTag { tag :: Text } deriving (Show, Generic)
instance FromForm TodoTag

data Todo = TodoItem { todoID :: Int, todo :: Text, done :: Bool, tags :: [TodoTag] }
          deriving (Show, Generic)

instance FromForm Todo

--------------------------------------------------
data Countries = Countries
               | Country Text

instance FromRequest Countries where
  fromRequest (rq,_) = case pathInfo rq of
    "countries":_ -> Just Countries
    "country":cnm:_ -> Just $ Country cnm
    _ -> Nothing

instance ToURL Countries where
  toURL Countries = "/countries"
  toURL (Country cnm) = "/country/"<>cnm

--------------------------------------------------
type ExampleM = ReaderT (TVar ExampleState) IO
data ExampleState = ExampleState { todoState :: TodoList }

-- readTodoState :: ExampleM TodoList
readTodoState = ask >>= fmap todoState . liftIO . readTVarIO

--------------------------------------------------

countryH :: [Gapminder] -> Countries -> HtmlT ExampleM ()
countryH gapM Countries = do
  let countries = nub $ map country gapM
  ul_ $ forM_ countries $ \c -> li_ $ a_ [href_ $ toURL $ Country c] $ (toHtml c)
countryH gapM (Country c) = do
  let entries = filter ((==c) . country) gapM
  ul_ $ forM_ entries $ \e ->
    li_ $ "year: " <> toHtml (show $ year e) <> "  population: "<> toHtml (show $ pop e)


data BubblesDD = BubblesDD { _selYear :: Int} deriving Show
makeLenses ''BubblesDD

bubblesDD gapM = do
  let years = nub $ map year gapM
  selYear <<~ select (map showOpt years)
  h2_ "hello world"
  BubblesDD y <- getValue
  p_ (toHtml $ show $ y)
  clickAttrs <- onClickDo $ \dd -> do
    liftIO $ putStrLn $ "current state: "++show dd
    return Reset
  button_ (clickAttrs) "Print state"

--------------------------------------------------

todoListEditForm :: Monad m => View Text -> HtmlT m ()
todoListEditForm view = container_ $ do
  form_ [method_ "post", action_ (toURL $ UpdateTodoList FormLink)] $ do
    renderForm (Proxy :: Proxy TodoList) view
    button_ [type_ "submit"] "Save"

todoH :: TodoR -> HtmlT ExampleM ()

todoH ListTodos = container_ $ do
  TodoList titleT todosT _ <- readTodoState
  br_ []
  h4_ (toHtml titleT)
  a_ [type_ "button", class_ "btn btn-primary", href_ . toURL $ EditTodoList]
    "Edit List"
  widget_ . widgetBody_ $ forM_ todosT $ \(TodoItem idT nameT doneT tags) -> do
    container_ $ do
      div_ $ do
        toHtml $
          show idT <> ". "
          <> (if doneT then "DONE: " else "TODO: ")
          <> unpack nameT
          <> unpack (if length tags == 0 then ""
                     else " (" <> T.intercalate ", " (map tag tags) <> ")")

todoH EditTodoList = do
  tdos <- readTodoState
  todoListEditForm $ getView (Just tdos)

todoH (UpdateTodoList (Form tdos)) = do
  atom <- ask
  liftIO . atomically $
    modifyTVar atom (\st -> st { todoState = tdos })
  todoH ListTodos

todoH (UpdateTodoList (FormError v)) = do
  liftIO . putStrLn $ "UpdateTodoList error: " <> show (FormError v)
  todoListEditForm v

initialTodos = TodoList "My todos"
  [ TodoItem 1 "Make todo app" False [TodoTag "dev", TodoTag "work"]
  , TodoItem 2 "Have lunch" False [TodoTag "personal"]
  , TodoItem 3 "Buy bread" True []]
  "A field after a subform"

sidebar = rdashSidebar "Youido Example" (return ())
    [ ("Bubbles", "fas")  *~ #bubbles :/ Initial
    , ("Counties", "fas") *~ Countries
    , ("Todos", "fas") *~ ListTodos ]

inHeader :: Text -> Html ()
inHeader js = do
  script_ [] js

main :: IO ()
main = do
  gapM <- getDataset gapminder
  js <- TIO.readFile "form-repeat.js"
  atom <- newTVarIO $ ExampleState initialTodos
  let runIt :: Bool -> ExampleM a -> IO a
      runIt _ todoM = runReaderT todoM atom

  serveY runIt $ do
    dashdoGlobal
    dashdo #bubbles $ Dashdo (BubblesDD 1980) (bubblesDD gapM)
    port .= 3101
    lookupUser .= \_ _ _ -> return $ Just True
    wrapper .= \_ -> rdashWrapper "Youido Example" (inHeader js) sidebar
    hHtmlT $ countryH gapM
    hHtmlT todoH
