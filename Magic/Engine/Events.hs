module Magic.Engine.Events (
    -- * Executing effects
    executeEffect, raise, applyReplacementEffects,

    -- * Compiling effects
    -- | These functions all immediately execute their effect, bypassing any
    -- replacement effects that might apply to them. They will cause triggered
    -- abilities to trigger.
    compileEffect,
    untapPermanent, drawCard, moveObject, moveAllObjects, shuffleLibrary, tick
  ) where

import Magic.Core
import Magic.IdList (Id)
import qualified Magic.IdList as IdList
import Magic.Labels
import Magic.Types
import Magic.Engine.Types

import Control.Applicative ((<$>))
import Control.Monad (forM_,)
import qualified Control.Monad.State as State
import Data.Either (partitionEithers)
import Data.Label.Pure (get, set)
import Data.Label.PureM (gets, puts, (=:))
import Data.List ((\\))
import Data.Monoid ((<>))
import Data.Traversable (for)
import Prelude hiding (interact)


-- | Execute a one-shot effect, applying replacement effects and triggering abilities.
-- TODO Return [Event] what actually happened
executeEffect :: OneShotEffect -> Engine ()
executeEffect e = applyReplacementEffects e >>= mapM_ compileEffect

-- | Raise an event, triggering abilities.
raise :: Event -> Engine ()
raise event = do
  -- TODO handle triggered abilities
  world <- State.get
  interact (LogEvent event world)
  return ()


-- [616] Interaction of Replacement and/or Prevention Effects
-- TODO Handle multiple effects (in a single event) at once, to be able to adhere
-- to APNAP order; see http://draw3cards.com/questions/9618
applyReplacementEffects :: OneShotEffect -> Engine [OneShotEffect]
applyReplacementEffects eff = do
    objects <- map snd <$> view allObjects
    go (concatMap (get replacementEffects) objects) eff
  where
    go :: [ReplacementEffect] -> OneShotEffect -> Engine [OneShotEffect]
    go availableEffects effectToReplace = do
      p <- affectedPlayer effectToReplace
      let (notApplicable, applicable) =
            partitionEithers $ map (\f -> maybe (Left f) (\m -> Right (f, m)) (f effectToReplace)) availableEffects
      if null applicable
        then return [effectToReplace]
        else do
          ((chosen, mReplacements), notChosen) <-
            askQuestion p (AskPickReplacementEffect applicable)
          replacements <- executeMagic mReplacements
          -- TODO Resolve replacements in affected player APNAP order.
          fmap concat $ for replacements (go (map fst notChosen ++ notApplicable))

-- [616.1] The affected player chooses which replacement effect to apply first.
affectedPlayer :: OneShotEffect -> Engine PlayerRef
affectedPlayer e =
  case e of
    WillMoveObject o _ _          -> controllerOf o
    Will (AdjustLife p _)         -> return p
    Will (DamageObject _ o _ _ _) -> controllerOf o
    Will (DamagePlayer _ p _ _ _) -> return p
    Will (ShuffleLibrary p)       -> return p
    Will (DrawCard p)             -> return p
    Will (DestroyPermanent i _)   -> controllerOf (Battlefield, i)
    Will (TapPermanent i)         -> controllerOf (Battlefield, i)
    Will (UntapPermanent i)       -> controllerOf (Battlefield, i)
    Will (AddCounter o _)         -> controllerOf o
    Will (RemoveCounter o _)      -> controllerOf o
    Will (CreateObject o)         -> return (get controller o)
    Will (AddToManaPool p _)      -> return p
    Will (SpendFromManaPool p _)  -> return p
    Will (AttachPermanent o _ _)  -> controllerOf o  -- debatable
    Will (RemoveFromCombat i)     -> controllerOf (Battlefield, i)
    Will (PlayLand o)             -> controllerOf o
    Will (LoseGame p)             -> return p
  where controllerOf o = gets (object o .^ controller)



-- COMPILATION OF EFFECTS


-- | Compile and execute an effect.
compileEffect :: OneShotEffect -> Engine ()
compileEffect e =
  -- TODO Return [Event] what actually happened
  case e of
    WillMoveObject rObj rToZone obj -> moveObject rObj rToZone obj
    Will (TapPermanent i)           -> tapPermanent i
    Will (UntapPermanent i)         -> untapPermanent i
    Will (DrawCard rp)              -> drawCard rp
    Will (ShuffleLibrary rPlayer)   -> shuffleLibrary rPlayer
    Will (PlayLand ro)              -> playLand ro
    Will (AddToManaPool p pool)     -> addToManaPool p pool
    Will (SpendFromManaPool p pool) -> spendFromManaPool p pool
    Will (DamagePlayer source p amount isCombatDamage isPreventable) -> damagePlayer source p amount isCombatDamage isPreventable
    _ -> error "compileEffect: effect not implemented"

tapPermanent :: Id -> Engine ()
tapPermanent i = do
  Just ts <- gets (object (Battlefield, i) .^ tapStatus)
  case ts of
    Untapped -> do
      object (Battlefield, i) .^ tapStatus =: Just Tapped
      raise (Did (TapPermanent i))
    Tapped   -> return ()

-- | Cause a permanent on the battlefield to untap. If it was previously tapped, a 'Did' 'UntapPermanent' event is raised.
untapPermanent :: Id -> Engine ()
untapPermanent i = do
  Just ts <- gets (object (Battlefield, i) .^ tapStatus)
  case ts of
    Untapped -> return ()
    Tapped -> do
      object (Battlefield, i) .^ tapStatus =: Just Untapped
      raise (Did (UntapPermanent i))

-- | Cause the given player to draw a card. If a card was actually drawn, a 'Did' 'DrawCard' event is raised. If not, the player loses the game the next time state-based actions are checked.
drawCard :: PlayerRef -> Engine ()
drawCard rp = do
  lib <- gets (players .^ listEl rp .^ library)
  case IdList.toList lib of
    []          -> do
      players .^ listEl rp .^ failedCardDraw =: True
    (ro, o) : _ -> do
      executeEffect (WillMoveObject (Library rp, ro) (Hand rp) o)
      -- TODO Only raise event if card was actually moved
      raise (Did (DrawCard rp))

-- | Cause an object to move from one zone to another in the specified form. If the object was actually moved, a 'DidMoveObject' event is raised.
moveObject :: ObjectRef -> ZoneRef -> Object -> Engine ()
moveObject (rFromZone, i) rToZone obj = do
  mObj <- IdList.removeM (compileZoneRef rFromZone) i
  case mObj of
    Nothing -> return ()
    Just _  -> do
      t <- tick
      newId <- IdList.snocM (compileZoneRef rToZone) (set timestamp t obj)
      raise (DidMoveObject rFromZone (rToZone, newId))

-- | @moveAllObjects z1 z2@ moves all objects from zone @z1@ to zone @z2@, raising a 'DidMoveObject' event for every object that was moved this way.
moveAllObjects :: ZoneRef -> ZoneRef -> Engine ()
moveAllObjects rFromZone rToZone = do
  ois <- IdList.toList <$> gets (compileZoneRef rFromZone)
  forM_ ois $ \(i, o) -> moveObject (rFromZone, i) rToZone o

-- | Shuffle a player's library. A 'ShuffleLibrary' event is raised.
shuffleLibrary :: PlayerRef -> Engine ()
shuffleLibrary rPlayer = do
  let libraryLabel = players .^ listEl rPlayer .^ library
  lib <- gets libraryLabel
  lib' <- IdList.shuffle lib
  puts libraryLabel lib'
  raise (Did (ShuffleLibrary rPlayer))

playLand :: ObjectRef -> Engine ()
playLand ro = gets (object ro) >>= moveObject ro Battlefield

addToManaPool :: PlayerRef -> ManaPool -> Engine ()
addToManaPool p pool = do
  player p .^ manaPool ~: (pool <>)
  raise (Did (AddToManaPool p pool))

spendFromManaPool :: PlayerRef -> ManaPool -> Engine ()
spendFromManaPool p pool = do
  player p .^ manaPool ~: (\\ pool)
  raise (Did (SpendFromManaPool p pool))

damagePlayer :: Object -> PlayerRef -> Int -> Bool -> Bool -> Engine ()
damagePlayer source p amount isCombatDamage isPreventable = do
  player p .^ life ~: subtract amount
  raise (Did (DamagePlayer source p amount isCombatDamage isPreventable))

tick :: Engine Timestamp
tick = do
  t <- gets time
  time ~: succ
  return t