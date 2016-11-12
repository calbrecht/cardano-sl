{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE UndecidableInstances  #-}

-- | Monadic layer for collecting stats

module Pos.Statistics.MonadStats
       ( MonadStats (..)
       , NoStatsT
       , getNoStatsT
       , StatsT
       , getStatsT
       ) where

import           Control.Monad.Catch      (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Except     (ExceptT)
import           Control.Monad.Trans      (MonadTrans)
import           Control.TimeWarp.Logging (WithNamedLogger (..))
import           Control.TimeWarp.Rpc     (MonadDialog, MonadResponse, MonadTransfer (..),
                                           hoistRespCond)
import           Control.TimeWarp.Timed   (MonadTimed (..), ThreadId)
import qualified Data.Binary              as Binary
import           Data.Maybe               (fromMaybe)
import           Data.SafeCopy            (SafeCopy)
import           Focus                    (Decision (Remove), alterM)
import           Serokell.Util            (show')
import qualified STMContainers.Map        as SM
import           System.IO.Unsafe         (unsafePerformIO)
import           Universum
import           Pos.Ssc.Class.Storage   (SscStorageClass)

import           Pos.DHT                  (DHTResponseT, MonadDHT, MonadMessageDHT (..),
                                           WithDefaultMsgHeader)
import           Pos.DHT.Real             (KademliaDHT)
import           Pos.Slotting             (MonadSlots (..))
import           Pos.State                (MonadDB (..), getStatRecords, newStatRecord)
import           Pos.Statistics.StatEntry (StatLabel (..))
import           Pos.Types                (Timestamp (..))
import           Pos.Util.JsonLog         (MonadJL)
import           Pos.Ssc.Class.Types      (SscTypes)

-- | `MonadStats` is a monad which has methods for stats collecting
class Monad m => MonadStats m where
    statLog :: StatLabel l => l -> EntryType l -> m ()
    resetStat :: StatLabel l => l -> Timestamp -> m ()
    getStats :: StatLabel l => l -> m (Maybe [(Timestamp, EntryType l)])

    -- | Default convenience method, which we can override
    -- (to truly do nothing in `NoStatsT`, for example)
    logStatM :: StatLabel l => l -> m (EntryType l) -> m ()
    logStatM label action = action >>= statLog label

-- TODO: is there a way to avoid such boilerplate for transformers?
instance MonadStats m => MonadStats (KademliaDHT m) where
    statLog label = lift . statLog label
    resetStat label = lift . resetStat label
    getStats = lift . getStats

instance MonadStats m => MonadStats (ReaderT a m) where
    statLog label = lift . statLog label
    resetStat label = lift . resetStat label
    getStats = lift . getStats

instance MonadStats m => MonadStats (StateT a m) where
    statLog label = lift . statLog label
    resetStat label = lift . resetStat label
    getStats = lift . getStats

instance MonadStats m => MonadStats (ExceptT e m) where
    statLog label = lift . statLog label
    resetStat label = lift . resetStat label
    getStats = lift . getStats

instance MonadStats m => MonadStats (DHTResponseT m) where
    statLog label = lift . statLog label
    resetStat label = lift . resetStat label
    getStats = lift . getStats

type instance ThreadId (NoStatsT m) = ThreadId m
type instance ThreadId (StatsT m) = ThreadId m

newtype NoStatsT m a = NoStatsT
    { getNoStatsT :: m a
    } deriving (Functor, Applicative, Monad, MonadTimed, MonadThrow, MonadCatch,
               MonadMask, MonadIO, MonadDB ssc, WithNamedLogger, MonadDialog p,
               MonadDHT, MonadMessageDHT, MonadResponse, MonadSlots, WithDefaultMsgHeader,
               MonadJL)

instance MonadTransfer m => MonadTransfer (NoStatsT m) where
    sendRaw addr p = NoStatsT $ sendRaw addr p
    listenRaw binding sink = NoStatsT $ listenRaw binding (hoistRespCond getNoStatsT sink)
    close = NoStatsT . close

instance MonadTrans NoStatsT where
    lift = NoStatsT

instance Monad m => MonadStats (NoStatsT m) where
    statLog _ _ = pure ()
    getStats _ = pure $ pure []
    resetStat _ _ = pure ()
    logStatM _ _ = pure ()

newtype StatsT m a = StatsT
    { getStatsT :: m a
    } deriving (Functor, Applicative, Monad, MonadTimed, MonadThrow, MonadCatch,
               MonadMask, MonadIO, MonadDB ssc, WithNamedLogger, MonadDialog p,
               MonadDHT, MonadMessageDHT, MonadResponse, MonadSlots, WithDefaultMsgHeader,
               MonadJL)

instance MonadTransfer m => MonadTransfer (StatsT m) where
    sendRaw addr p = StatsT $ sendRaw addr p
    listenRaw binding sink = StatsT $ listenRaw binding (hoistRespCond getStatsT sink)
    close = StatsT . close

instance MonadTrans StatsT where
    lift = StatsT

-- TODO: =\
statsMap :: SM.Map Text LByteString
statsMap = unsafePerformIO SM.newIO

instance (SscStorageClass ssc, SafeCopy ssc, MonadIO m, MonadDB ssc m) => MonadStats (StatsT m) where
    statLog label entry = do
        liftIO $ atomically $ SM.focus update (show' label) statsMap
        return ()
      where
        update = alterM $ \v -> return $ fmap Binary.encode $
            mappend entry . Binary.decode <$> v <|> Just entry

    resetStat label ts = do
        mval <- liftIO $ atomically $ SM.focus reset (show' label) statsMap
        let val = fromMaybe mempty $ Binary.decode <$> mval
        lift $ newStatRecord @ssc label ts val
      where
        reset old = return (old, Remove)

    getStats = lift . getStatRecords @ssc
