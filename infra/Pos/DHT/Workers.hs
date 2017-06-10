{-# LANGUAGE MultiParamTypeClasses #-}

module Pos.DHT.Workers
       ( DhtWorkMode
       , dhtWorkers
       ) where

import           Universum

import qualified Data.ByteString.Lazy       as BS
import           Data.Store                 (Store, encode)
import           Formatting                 (sformat, (%))
import           Mockable                   (Delay, Fork, Mockable)
import           Network.Kademlia           (KademliaSnapshot, takeSnapshot)
import           System.Wlog                (WithLogger, logNotice)

import           Pos.Binary.Infra.DHTModel  ()
import           Pos.Communication.Protocol (OutSpecs, WorkerSpec, localOnNewSlotWorker)
import           Pos.Core.Slotting          (flattenSlotId)
import           Pos.Core.Types             (slotIdF)
import           Pos.DHT.Constants          (kademliaDumpInterval)
import           Pos.DHT.Model.Types        (DHTKey)
import           Pos.DHT.Real.Types         (KademliaDHTInstance (..))
import           Pos.Discovery.Class        (MonadDiscovery)
import           Pos.Reporting              (MonadReportingMem)
import           Pos.Shutdown               (MonadShutdownMem)
import           Pos.Slotting.Class         (MonadSlots)

type DhtWorkMode m =
    ( WithLogger m
    , MonadSlots m
    , MonadIO m
    , MonadMask m
    , Mockable Fork m
    , Mockable Delay m
    , MonadReportingMem m
    , MonadShutdownMem m
    , MonadDiscovery m
    )

dhtWorkers
    :: ( DhtWorkMode m
       , Store (KademliaSnapshot DHTKey) -- CSL-1122: remove this, required for @decodeEx@
       )
    => KademliaDHTInstance -> ([WorkerSpec m], OutSpecs)
dhtWorkers kademliaInst = first pure (dumpKademliaStateWorker kademliaInst)

dumpKademliaStateWorker
    :: ( DhtWorkMode m
       , Store (KademliaSnapshot DHTKey) -- CSL-1122: remove this, required for @decodeEx@
       )
    => KademliaDHTInstance
    -> (WorkerSpec m, OutSpecs)
dumpKademliaStateWorker kademliaInst = localOnNewSlotWorker True $ \slotId ->
    when (flattenSlotId slotId `mod` kademliaDumpInterval == 0) $ do
        let dumpFile = kdiDumpPath kademliaInst
        logNotice $ sformat ("Dumping kademlia snapshot on slot: "%slotIdF) slotId
        let inst = kdiHandle kademliaInst
        snapshot <- liftIO $ takeSnapshot inst
        liftIO . BS.writeFile dumpFile $ BS.fromStrict $ encode snapshot
