{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}

-- | A “dynamic state” implementation of SSC. Nodes exchange commitments,
-- openings, and shares, and in the end arrive at a shared seed.
--
-- See https://eprint.iacr.org/2015/889.pdf (“A Provably Secure
-- Proof-of-Stake Blockchain Protocol”), section 4 for more details.

module Pos.Ssc.DynamicState.Types
       (
         -- * Instance types
         DSPayload(..)
       , DSProof(..)
       , DSMessage(..)
       , SendSsc(..)
       , filterDSPayload
       , mkDSProof
       , verifyDSPayload

       -- * Lenses
       -- ** DSPayload
       , mdCommitments
       , mdOpenings
       , mdShares
       , mdVssCertificates

       -- * Utilities
       , hasCommitment
       , hasOpening
       , hasShares
       ) where

import           Control.Lens              (makeLenses, (^.))
import           Data.Binary               (Binary)
import qualified Data.HashMap.Strict       as HM
import           Data.Ix                   (inRange)
import           Data.MessagePack          (MessagePack)
import           Data.SafeCopy             (base, deriveSafeCopySimple)
import           Data.Text.Buildable       (Buildable (..))
import           Formatting                (bprint, (%))
import           Serokell.Util             (VerificationRes, isVerSuccess, listJson,
                                            verifyGeneric)
import           Universum

import           Pos.Constants             (k)
import           Pos.Crypto                (Hash, PublicKey, Share, hash)
import           Pos.Ssc.Class.Types       (SscTypes (SscPayload))
import           Pos.Ssc.DynamicState.Base (CommitmentsMap, Opening, OpeningsMap,
                                            SharesMap, SignedCommitment, VssCertificate,
                                            VssCertificatesMap, checkCert, isCommitmentId,
                                            isOpeningId, isSharesId,
                                            verifySignedCommitment)
import           Pos.Types                 (MainBlockHeader, SlotId (..), headerSlot)

import           Control.TimeWarp.Rpc (Message (..))

----------------------------------------------------------------------------
-- SscMessage
----------------------------------------------------------------------------

data DSMessage
    = DSCommitment !PublicKey
                   !SignedCommitment
    | DSOpening !PublicKey
                !Opening
    | DSShares !PublicKey
               (HashMap PublicKey Share)
    | DSVssCertificate !PublicKey
                       !VssCertificate
    deriving (Show)

deriveSafeCopySimple 0 'base ''DSMessage

----------------------------------------------------------------------------
-- SscPayload
----------------------------------------------------------------------------

-- | MPC-related content of main body.
data DSPayload = DSPayload
    { -- | Commitments are added during the first phase of epoch.
      _mdCommitments     :: !CommitmentsMap
      -- | Openings are added during the second phase of epoch.
    , _mdOpenings        :: !OpeningsMap
      -- | Decrypted shares to be used in the third phase.
    , _mdShares          :: !SharesMap
      -- | Vss certificates are added at any time if they are valid and
      -- received from stakeholders.
    , _mdVssCertificates :: !VssCertificatesMap
    } deriving (Show, Generic)

deriveSafeCopySimple 0 'base ''DSPayload
makeLenses ''DSPayload

instance Binary DSPayload
instance MessagePack DSPayload

instance Buildable DSPayload where
    build DSPayload {..} =
        mconcat
            [ formatCommitments
            , formatOpenings
            , formatShares
            , formatCertificates
            ]
      where
        formatIfNotNull formatter l
            | null l = mempty
            | otherwise = bprint formatter l
        formatCommitments =
            formatIfNotNull
                ("  commitments from: "%listJson%"\n")
                (HM.keys _mdCommitments)
        formatOpenings =
            formatIfNotNull
                ("  openings from: "%listJson%"\n")
                (HM.keys _mdOpenings)
        formatShares =
            formatIfNotNull
                ("  shares from: "%listJson%"\n")
                (HM.keys _mdShares)
        formatCertificates =
            formatIfNotNull
                ("  certificates from: "%listJson%"\n")
                (HM.keys _mdVssCertificates)

{- |

Verify payload using header containing this payload.

For each DS datum we check:

  1. Whether it's stored in the correct block (e.g. commitments have to be in
     first k blocks, etc.)

  2. Whether the message itself is correct (e.g. commitment signature is
     valid, etc.)

We also do some general sanity checks.
-}
verifyDSPayload
    :: (SscPayload ssc ~ DSPayload)
    => MainBlockHeader ssc -> SscPayload ssc -> VerificationRes
verifyDSPayload header DSPayload {..} =
    verifyGeneric allChecks
  where
    slotId       = header ^. headerSlot
    epochId      = siEpoch slotId
    commitments  = _mdCommitments
    openings     = _mdOpenings
    shares       = _mdShares
    certificates = _mdVssCertificates
    isComm       = isCommitmentId slotId
    isOpen       = isOpeningId slotId
    isShare      = isSharesId slotId

    -- We *forbid* blocks from having commitments/openings/shares in blocks
    -- with wrong slotId (instead of merely discarding such commitments/etc)
    -- because it's the miner's responsibility not to include them into the
    -- block if they're late.
    --
    -- For commitments specifically, we also
    --   * check there are only commitments in the block
    --   * use verifySignedCommitment, which checks commitments themselves, e. g.
    --     checks their signatures (which includes checking that the
    --     commitment has been generated for this particular epoch)
    -- TODO: we might also check that all share IDs are different, because
    -- then we would be able to simplify 'calculateSeed' a bit – however,
    -- it's somewhat complicated because we have encrypted shares, shares in
    -- commitments, etc.
    commChecks =
        [ (null openings,
                "there are openings in a commitment block")
        , (null shares,
                "there are shares in a commitment block")
        , (let checkSignedComm = isVerSuccess .
                    uncurry (flip verifySignedCommitment epochId)
            in all checkSignedComm (HM.toList commitments),
                "verifySignedCommitment has failed for some commitments")
        ]

    -- For openings, we check that
    --   * there are only openings in the block
    openChecks =
        [ (null commitments,
                "there are commitments in an openings block")
        , (null shares,
                "there are shares in an openings block")
        ]

    -- For shares, we check that
    --   * there are only shares in the block
    shareChecks =
        [ (null commitments,
                "there are commitments in a shares block")
        , (null openings,
                "there are openings in a shares block")
        ]

    -- For all other blocks, we check that
    --   * there are no commitments, openings or shares
    otherBlockChecks =
        [ (null commitments,
                "there are commitments in an ordinary block")
        , (null openings,
                "there are openings in an ordinary block")
        , (null shares,
                "there are shares in an ordinary block")
        ]

    -- For all blocks (no matter the type), we check that
    --   * slot ID is in range
    --   * VSS certificates are signed properly
    otherChecks =
        [ (inRange (0, 6 * k - 1) (siSlot slotId),
                "slot id is outside of [0, 6k)")
        , (all checkCert (HM.toList certificates),
                "some VSS certificates aren't signed properly")
        ]

    allChecks = concat $ concat
        [ [ commChecks       | isComm ]
        , [ openChecks       | isOpen ]
        , [ shareChecks      | isShare ]
        , [ otherBlockChecks | all not [isComm, isOpen, isShare] ]
        , [ otherChecks ]
        ]


-- | Remove messages irrelevant to given slot id from payload.
filterDSPayload :: SlotId -> DSPayload -> DSPayload
filterDSPayload slotId DSPayload {..} =
    DSPayload
    { _mdCommitments = filteredCommitments
    , _mdOpenings = filteredOpenings
    , _mdShares = filteredShares
    , ..
    }
  where
    filteredCommitments = filterDo isCommitmentId _mdCommitments
    filteredOpenings = filterDo isOpeningId _mdOpenings
    filteredShares = filterDo isSharesId _mdShares
    filterDo
        :: Monoid container
        => (SlotId -> Bool) -> container -> container
    filterDo checker container
        | checker slotId = container
        | otherwise = mempty

----------------------------------------------------------------------------
-- SscProof
----------------------------------------------------------------------------

-- | Proof of MpcData.
-- We can use ADS for commitments, opennings, shares as well,
-- if we find it necessary.
data DSProof = DSProof
    { mpCommitmentsHash     :: !(Hash CommitmentsMap)
    , mpOpeningsHash        :: !(Hash OpeningsMap)
    , mpSharesHash          :: !(Hash SharesMap)
    , mpVssCertificatesHash :: !(Hash VssCertificatesMap)
    } deriving (Show, Eq, Generic)

deriveSafeCopySimple 0 'base ''DSProof

instance Binary DSProof
instance MessagePack DSProof

mkDSProof :: DSPayload -> DSProof
mkDSProof DSPayload {..} =
    DSProof
    { mpCommitmentsHash = hash _mdCommitments
    , mpOpeningsHash = hash _mdOpenings
    , mpSharesHash = hash _mdShares
    , mpVssCertificatesHash = hash _mdVssCertificates
    }

----------------------------------------------------------------------------
-- Utility functions
----------------------------------------------------------------------------

hasCommitment :: PublicKey -> DSPayload -> Bool
hasCommitment pk md = HM.member pk (_mdCommitments md)

hasOpening :: PublicKey -> DSPayload -> Bool
hasOpening pk md = HM.member pk (_mdOpenings md)

hasShares :: PublicKey -> DSPayload -> Bool
hasShares pk md = HM.member pk (_mdShares md)

--Communication

-- | Message: some node has sent SscMessage
data SendSsc
    = SendCommitment PublicKey
                     SignedCommitment
    | SendOpening PublicKey
                  Opening
    | SendShares PublicKey
                 (HashMap PublicKey Share)
    | SendVssCertificate PublicKey
                         VssCertificate
    deriving (Show, Generic)

instance Binary SendSsc

instance Message SendSsc where
    messageName _ = "SendSsc"
