module Component.Projects.Types where

import Prologue
import Analytics (class IsEvent, Event)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Lens (Lens', has)
import Data.Lens.Record (prop)
import Data.Symbol (SProxy(..))
import Foreign.Class (class Decode, class Encode)
import Foreign.Generic.EnumEncoding (defaultGenericEnumOptions, genericDecodeEnum, genericEncodeEnum)
import Gist (Gist, GistId)
import Network.RemoteData (RemoteData(..), _Loading)

-----------------------------------------------------------
data Lang
  = Marlowe
  | Haskell
  | Javascript
  | Blockly
  | Actus

derive instance eqLang :: Eq Lang

derive instance genericLang :: Generic Lang _

instance encodeLang :: Encode Lang where
  encode value = genericEncodeEnum defaultGenericEnumOptions value

instance decodeLang :: Decode Lang where
  decode value = genericDecodeEnum defaultGenericEnumOptions value

-----------------------------------------------------------
instance showLang :: Show Lang where
  show lang = genericShow lang

data Action
  = LoadProjects
  | LoadProject Lang GistId
  | Cancel

defaultEvent :: String -> Event
defaultEvent action = { category: Just "Projects", action, label: Nothing, value: Nothing }

instance isEventAction :: IsEvent Action where
  toEvent LoadProjects = Just $ defaultEvent "LoadProjects"
  toEvent (LoadProject lang _) = Just { category: Just "Projects", action: "LoadProject", label: Just (show lang), value: Nothing }
  toEvent Cancel = Just $ defaultEvent "Cancel"

type State
  = { projects :: RemoteData String (Array Gist)
    }

emptyState :: State
emptyState = { projects: NotAsked }

_projects :: Lens' State (RemoteData String (Array Gist))
_projects = prop (SProxy :: SProxy "projects")

modalIsLoading :: State -> Boolean
modalIsLoading = has (_projects <<< _Loading)
