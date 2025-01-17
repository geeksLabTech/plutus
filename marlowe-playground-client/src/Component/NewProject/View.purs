module Component.NewProject.View where

import Prologue hiding (div)
import Component.Modal.ViewHelpers (modalHeader)
import Component.NewProject.Types (Action(..), State, _error)
import Component.Projects.Types (Lang(..))
import Data.Lens ((^.))
import Effect.Aff.Class (class MonadAff)
import Halogen (ClassName(..), ComponentHTML)
import Halogen.Classes (fontSemibold, marloweLogo, modalContent, newProjectBlocklyIcon, newProjectHaskellIcon, newProjectJavascriptIcon, textBase, textSm)
import Halogen.HTML (div, div_, h3, img, span, text)
import Halogen.HTML.Events (onClick)
import Halogen.HTML.Properties (class_, classes, src)
import MainFrame.Types (ChildSlots)

render ::
  forall m.
  MonadAff m =>
  State ->
  ComponentHTML Action ChildSlots m
render state =
  div_
    [ modalHeader "New Project" (Just Cancel)
    , div [ classes [ modalContent, ClassName "new-project-container" ] ]
        [ h3 [ classes [ textBase, fontSemibold ] ] [ text "Please choose your initial coding environment" ]
        , div [ classes [ ClassName "environment-selector-group" ] ] (map link [ Haskell, Javascript, Marlowe, Blockly ])
        , renderError (state ^. _error)
        ]
    ]
  where
  renderError Nothing = text ""

  renderError (Just err) = div [ class_ (ClassName "error") ] [ text err ]

  link lang =
    div
      [ classes [ ClassName "environment-selector" ]
      , onClick (const <<< Just $ CreateProject lang)
      ]
      [ img [ src $ langIcon lang ]
      , span [ classes [ textSm, fontSemibold ] ]
          [ text $ langTitle lang ]
      ]

  langIcon = case _ of
    Haskell -> newProjectHaskellIcon
    Javascript -> newProjectJavascriptIcon
    Marlowe -> marloweLogo
    Blockly -> newProjectBlocklyIcon
    _ -> "" -- The default should never happen but it's not checked at the type level

  langTitle = case _ of
    Haskell -> "Haskell Editor"
    Javascript -> "JS Editor"
    Marlowe -> "Marlowe"
    Blockly -> "Blockly"
    _ -> ""
