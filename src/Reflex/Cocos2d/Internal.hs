{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecursiveDo #-}
module Reflex.Cocos2d.Internal
    (
      mainScene
    , Builder
    , BuilderBase
    , hoist
    , embed
    , squash
    )
  where

import Data.Dependent.Sum ((==>))
import Data.IORef
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Monad.Ref
import Control.Monad.Exception
import Control.Lens
import Reflex
import Reflex.Host.Class

import Foreign.Ptr (castPtr)
import Foreign.Hoppy.Runtime (Decodable(..), CppPtr(..))

import Graphics.UI.Cocos2d.Node
import Graphics.UI.Cocos2d.Scene
import Graphics.UI.Cocos2d.Director

import Reflex.Cocos2d.Class


-- mostly borrowed from Reflex.Dom.Internal
data BuilderState t m = BuilderState
    { _builderVoidActions :: ![Event t (m ())]
    , _builderFinalizers  :: IO ()
    }

hoistBuilderState :: Reflex t => (m () -> n ()) -> BuilderState t m -> BuilderState t n
hoistBuilderState f (BuilderState vas fin) = BuilderState (fmap f <$> vas)  fin

instance Monoid (BuilderState t m) where
    mempty = BuilderState [] (return ())
    (BuilderState va0 fin0) `mappend` (BuilderState va1 fin1) =
      -- the later finalizers should come first
      BuilderState (va0 `mappend` va1) (fin1 `mappend` fin0)

builderVoidActions ::
  forall t m.
  Lens' (BuilderState t m) [Event t (m ())]
builderVoidActions f (BuilderState act fin)
  = fmap (\ act' -> BuilderState act' fin) (f act)
{-# INLINE builderVoidActions #-}
builderFinalizers ::
  forall t m.
  Lens' (BuilderState t m) (IO ())
builderFinalizers f (BuilderState act fin)
  = fmap (\ fin' -> BuilderState act fin') (f fin)
{-# INLINE builderFinalizers #-}

newtype Builder t m a = Builder (ReaderT (NodeBuilderEnv t) (StateT (BuilderState t m) m) a)
    deriving ( Monad, Functor, Applicative
             , MonadReader (NodeBuilderEnv t)
             , MonadState (BuilderState t m)
             , MonadFix, MonadIO
             , MonadException, MonadAsyncException
             , MonadSample t, MonadHold t
             , MonadReflexCreateTrigger t, MonadSubscribeEvent t )

instance MonadTrans (Builder t) where
    lift = Builder . lift . lift

instance MonadRef m => MonadRef (Builder t m) where
    type Ref (Builder t m) = Ref m
    newRef = lift . newRef
    readRef = lift . readRef
    writeRef r = lift . writeRef r

-- run builder with a given env and empty state
runBuilder :: Builder t m a -> NodeBuilderEnv t -> BuilderState t m -> m (a, BuilderState t m)
runBuilder (Builder builder) env st =
    runStateT (runReaderT builder env) st

instance (Reflex t, MonadRef m, Ref m ~ Ref IO, MonadReflexCreateTrigger t m, MonadIO m)
  => MonadSequenceEvent t (Builder t m) where
    type Sequenceable (Builder t m) = m
    seqEvent_ e = Builder $ builderVoidActions %= (e:)
    seqEventMaybe e = do
        run <- view runWithActions
        (eResult, trigger) <- newEventWithTriggerRef
        seqForEvent_ e $ \o -> do
            o >>= \case
              Just x -> liftIO $ readRef trigger >>= mapM_ (\t -> run ([t ==> x], return ()))
              _ -> return ()
        return eResult

-- custom hoist instead of MFunctor because we need more constraints
hoist :: (Reflex t, Monad n)
      => (forall a. m a -> n a) -> Builder t m b -> Builder t n b
hoist f ba = do
    env <- ask
    -- XXX: hack, starting with empty state
    (a, st) <- lift $ f (runBuilder ba env mempty)
    modify' (`mappend` (hoistBuilderState f st))
    return a

-- for things like RandT, we can achieve that with seqEvent coupled
-- with hoist, i.e.,
-- Event t (RandT g m' (Maybe a)) -> tf (RandT g m') (Event t a)
-- tf (RandT g m') (Event t a) -> tf m' (Event t a)
-- tf (tf m') (Maybe a) -> tf (tf m') (Event t a)

-- we can't implement MMonad because the 'flattening' of Builder would
-- require more capabilities than just plain Monad
embed :: forall t m n b.
         ( Reflex t
         , MonadRef n, Ref n ~ Ref IO, MonadReflexCreateTrigger t n
         , MonadIO n, MonadFix n, MonadHold t n )
      => (forall a. m a -> Builder t n a) -> Builder t m b -> Builder t n b
embed f ba = do
      env <- ask
      -- XXX: hack, starting with empty state
      (a, st) <- f (runBuilder ba env mempty)
      -- for each new event, needs to change it to an actual firing event
      (newChildBuilt, newChildBuiltTriggerRef) <- newEventWithTriggerRef
      let newSt :: BuilderState t (Builder t n)
          newSt = hoistBuilderState f st
          run = env ^. runWithActions
          onNewChildBuilt :: Event t (n ()) -> [Event t (n ())] -> Maybe (Event t (n ()))
          onNewChildBuilt _ [] = Nothing
          onNewChildBuilt acc vas = Just $ mergeWith (>>) (acc:reverse vas)
          newVas' :: [Event t (n ())]
          newVas' = ffor (newSt^.builderVoidActions) . fmap $ \bd -> do
            (postBuildE, postBuildTr) <- newEventWithTriggerRef
            let firePostBuild = readRef postBuildTr >>= mapM_ (\t -> run ([t ==> ()], return ()))
            (_, builderState) <- runBuilder bd (env & postBuildEvent .~ postBuildE) mempty
            liftIO $ readRef newChildBuiltTriggerRef
                      >>= mapM_ (\t -> run ([t ==> builderState^.builderVoidActions], firePostBuild))
      newChildVa <- switch <$> accumMaybe onNewChildBuilt (never :: Event t (n ())) newChildBuilt
      builderVoidActions %= ((newChildVa:) . (newVas'++))
      -- attach the finalizers
      -- XXX: for the moment ignore the finalizers from the childs
      -- as there is no easy way...
      addFinalizer $ newSt^.builderFinalizers
      return a

squash :: ( Reflex t
          , MonadRef m, Ref m ~ Ref IO, MonadReflexCreateTrigger t m
          , MonadIO m, MonadFix m, MonadHold t m )
       => Builder t (Builder t m) a -> Builder t m a
squash = embed id

instance ( Reflex t, MonadRef m, Ref m ~ Ref IO, MonadReflexCreateTrigger t m
         , MonadIO m, MonadHold t m )
        => MonadSequenceHold t (Builder t m) where
    type Finalizable (Builder t m) = IO
    seqHold init e = do
        p <- asks $ view parent
        oldState <- Builder $ get <* put (BuilderState [] (return ()))
        result0 <- init
        state <- Builder $ get <* put oldState
        let voidAction0 = mergeWith (flip (>>)) (state^.builderVoidActions)
        (newChildBuilt, newChildBuiltTriggerRef) <- newEventWithTriggerRef
        seqEvent_ <=< switchPromptly voidAction0 $
              mergeWith (flip (>>)) . view (_2.builderVoidActions) <$> newChildBuilt
        finalizerBeh <- hold (state^.builderFinalizers) (view (_2.builderFinalizers) <$> newChildBuilt)
        builderEnv <- ask
        let run = builderEnv ^. runWithActions
        seqForEvent_ e $ \bd -> do
            liftIO =<< sample finalizerBeh
            (postBuildE, postBuildTr) <- newEventWithTriggerRef
            let firePostBuild = readRef postBuildTr >>= mapM_ (\t -> run ([t ==> ()], return ()))
            (r, builderState) <- flip (runBuilder bd) mempty $
                builderEnv & parent .~ p
                           & postBuildEvent .~ postBuildE
            liftIO $ readRef newChildBuiltTriggerRef
                    >>= mapM_ (\t -> run ([t ==> (r, builderState)], firePostBuild))
        return (result0, fst <$> newChildBuilt)
    addFinalizer a = Builder $ builderFinalizers %= (a >>)

-- | A custom class for specifying the requirements on a common builder base
class
  ( Reflex t
  , MonadReflexCreateTrigger t m, MonadSubscribeEvent t m
  , MonadSample t m, MonadHold t m, MonadFix m
  , MonadRef m, Ref m ~ Ref IO
  , MonadIO m
  ) => BuilderBase t m where

instance (m ~ HostFrame Spider) => BuilderBase Spider m where

-- | Construct a new scene with a NodeBuilder
mainScene :: Builder Spider (HostFrame Spider) a -> IO a
mainScene bd = do
    scene <- scene_create
    dtor <- director_getInstance
    winSize <- decode =<< director_getWinSize dtor
    recRef <- newIORef (False, [], []) -- (running, saved_dm)
    result <- runSpiderHost $ mdo
        let processTrigger [] [] = writeIORef recRef (False, [], [])
            processTrigger [] aft = do
              writeIORef recRef (True, [], [])
              foldl (flip (>>)) (return ()) aft
              (_, saved, savedAft) <- readIORef recRef
              processTrigger saved savedAft
            processTrigger es aft = do
              writeIORef recRef (True, [], [])
              runSpiderHost $ do
                  va <- fireEventsAndRead es $ sequence =<< readEvent voidActionHandle
                  runHostFrame $ sequence_ va
              (_, saved, savedAft) <- readIORef recRef
              processTrigger saved (aft++savedAft)
            runWithActions (dm, aft) = do
              (running, saved, savedAft) <- readIORef recRef
              if running
                then writeIORef recRef (running, dm++saved, aft:savedAft)
                else processTrigger dm [aft]
        (postBuildE, postBuildTr) <- newEventWithTriggerRef
        -- tick events
        ticks <- newEventWithTrigger $ \tr -> liftIO $ do
            sch <- director_getScheduler dtor
            let target = castPtr $ toPtr dtor
            scheduler_scheduleWithInterval sch
              (\ss -> runWithActions ([tr ==> ss], return ()))
              target 0 False "ticks"
            return $ scheduler_unschedule sch "ticks" target
        (result, builderState) <- runHostFrame . flip (runBuilder bd) mempty $
            NodeBuilderEnv (toNode scene) winSize postBuildE ticks runWithActions
        voidActionHandle <- subscribeEvent . mergeWith (flip (>>)) $ builderState^.builderVoidActions
        liftIO $ readRef postBuildTr >>= mapM_ (\t -> runWithActions ([t ==> ()], return ()))
        return result
    director_getInstance >>= flip director_runWithScene scene
    return result

