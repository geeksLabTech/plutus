module Page.Welcome.Types
  ( State
  , Card(..)
  , Action(..)
  , WalletNicknameOrIdError(..)
  ) where

import Prologue
import Analytics (class IsEvent, defaultEvent, toEvent)
import Clipboard (Action) as Clipboard
import Component.Contacts.Types (WalletDetails, WalletLibrary, WalletNickname, WalletNicknameError)
import Component.InputField.Types (Action, State) as InputField
import Component.InputField.Types (class InputFieldError)
import Marlowe.PAB (PlutusAppId)
import Types (WebData)

-- TODO (possibly): The Contacts submodule used in the Dashboard has some properties and
-- functionality that's similar to some of what goes on here. It might be worth generalising it so
-- it works in both cases, and including it as a submodule here too.
type State
  = { card :: Maybe Card
    -- Note [CardOpen]: As well as making the card a Maybe, we add an additional cardOpen flag.
    -- When closing a card we set this to false instead of setting the card to Nothing, and that
    -- way we can use CSS transitions to animate it on the way out as well as the way in. This is
    -- preferable to using the Halogen.Animation module (used for toasts), because in this case we
    -- need to simultaneously animate (fade in/out) the overlay, and because the animation for
    -- cards has to be different for different screen sizes (on large screens some cards slide in
    -- from the right) - and that's much easier to do with media queries.
    , cardOpen :: Boolean
    , walletLibrary :: WalletLibrary
    , walletNicknameOrIdInput :: InputField.State WalletNicknameOrIdError
    , walletNicknameInput :: InputField.State WalletNicknameError
    , walletId :: PlutusAppId
    , remoteWalletDetails :: WebData WalletDetails
    , enteringDashboardState :: Boolean
    }

data WalletNicknameOrIdError
  = UnconfirmedWalletNicknameOrId
  | NonexistentWalletNicknameOrId

derive instance eqWalletNicknameOrIdError :: Eq WalletNicknameOrIdError

instance inputFieldErrorWalletNicknameOrIdError :: InputFieldError WalletNicknameOrIdError where
  inputErrorToString UnconfirmedWalletNicknameOrId = "Looking up wallet..."
  inputErrorToString NonexistentWalletNicknameOrId = "Wallet not found"

data Card
  = GetStartedHelpCard
  | GenerateWalletHelpCard
  | UseNewWalletCard
  | UseWalletCard
  | LocalWalletMissingCard

derive instance eqCard :: Eq Card

data Action
  = OpenCard Card
  | CloseCard
  | GenerateWallet
  | WalletNicknameOrIdInputAction (InputField.Action WalletNicknameOrIdError)
  | OpenUseWalletCardWithDetails WalletDetails
  | WalletNicknameInputAction (InputField.Action WalletNicknameError)
  | ConnectWallet WalletNickname
  | ClearLocalStorage
  | ClipboardAction Clipboard.Action

-- | Here we decide which top-level queries to track as GA events, and how to classify them.
instance actionIsEvent :: IsEvent Action where
  toEvent (OpenCard _) = Nothing
  toEvent CloseCard = Nothing
  toEvent GenerateWallet = Just $ defaultEvent "GenerateWallet"
  toEvent (WalletNicknameOrIdInputAction inputFieldAction) = toEvent inputFieldAction
  toEvent (OpenUseWalletCardWithDetails _) = Nothing
  toEvent (WalletNicknameInputAction inputFieldAction) = toEvent inputFieldAction
  toEvent (ConnectWallet _) = Just $ defaultEvent "ConnectWallet"
  toEvent ClearLocalStorage = Just $ defaultEvent "ClearLocalStorage"
  toEvent (ClipboardAction _) = Just $ defaultEvent "ClipboardAction"
