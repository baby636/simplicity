{-# LANGUAGE ScopedTypeVariables, RecordWildCards #-}
-- | The module builds a Simplicity expression that mimics the behavour of a @CHECKSIG@ operation restricted to a @SIGHASH_ALL@ flag for Bitcoin.
-- This forms the mimial Simiplicity expression needed to secure funds in a Bitcoin-style blockchain.
-- This uses Schnorr signature verification specified in "Simplicity.Programs.LibSecp256k1".
module Simplicity.Bitcoin.Programs.CheckSigHashAll
-- :TODO:
-- - Add other sighash modes to the library
-- - Eliminate checkSigHashAll in favor of a generic checkSigHashFixed combinator in Core
-- - Rename this module *.SigHash
  ( Lib(Lib), mkLib
  -- * Operations
  , hashAll
  , sigHashAll
  , checkSigHashAll
  -- * Types
  , Hash
  -- * Example instances
  , lib
  ) where

import Prelude hiding (drop, take)

import Simplicity.Bitcoin.Primitive
import Simplicity.Bitcoin.Term
import Simplicity.Digest
import Simplicity.Functor
import qualified Simplicity.LibSecp256k1.Schnorr as Schnorr
import Simplicity.MerkleRoot
import Simplicity.Programs.Arith
import Simplicity.Programs.Bit
import Simplicity.Programs.Generic
import Simplicity.Programs.Sha256 hiding (Lib(Lib), lib)
import qualified Simplicity.Programs.Sha256 as Sha256
import qualified Simplicity.Programs.LibSecp256k1 as LibSecp256k1
import Simplicity.Tensor
import Simplicity.Ty

-- | A collection of core Simplicity expressions for Bitcoin-style signature hash modes.
-- Use 'mkLib' to construct an instance of this library.
data Lib term =
 Lib
  { -- | This expression returns a hash of basic signed transaction data.
    -- This includes:
    --
    -- * Hash of all the transaction inputs data.
    --
    -- * Hash of all the transaction output data.
    --
    -- * The transactions lock time.
    --
    -- * The transactions version data.
    --
    -- * The index of the input currently being spend.
    --
    -- * The asset and amount of this input's UTXO being redeemed.
    hashAll :: term () Hash
    -- | This expression creates a digest of the pair of the 'commitmentRoot' of 'hashAll' with the result of evaluating 'hashAll'.
    -- This is the digest that needs to be signed for 'checkSigHashAll' to pass.
  , sigHashAll :: term () Hash
  }

instance SimplicityFunctor Lib where
  sfmap m Lib{..} =
   Lib
    { hashAll = m hashAll
    , sigHashAll = m sigHashAll
    }

-- | Build the Bitcoin signature hash 'Lib' library from its dependencies.
mkLib :: forall term. (Core term, Primitive term) => Sha256.Lib (Product CommitmentRoot term) -- ^ "Simplicity.Programs.Sha256"
                                                  -> Lib term
mkLib Sha256.Lib{..} = lib
 where
  hashAllProduct :: (Product CommitmentRoot term) () Hash
  hashAllProduct = ((scribe sigIv &&& blk1 >>> hb) &&& blk2 >>> hb) &&& blk3 >>> hb
   where
    sigIv = toWord256 . integerHash256 . ivHash $ sigHashTag
    hb = hashBlock
    annex = primitive AnnexHash &&& unit >>>
               match (take (scribe (toWord256 . integerHash256 . bsHash $ mempty)))
                     (drop iv &&& (oh &&& drop (scribe (toWord256 (2^255 + 256)))) >>> hb)
    -- :TODO: Add merkle path to avoid the bug that taproot has with repeated leaves at different depths.
    taprootPath = iv &&& (primitive ScriptCMR &&&
                  (((((primitive TapleafVersion &&& scribe (toWord8 0x80)) &&& zero word16) &&& zero word32) &&& zero word64)
                     &&& scribe (toWord128 (256 + 8)))) >>> hb
    blk1 = primitive InputsHash &&& primitive OutputsHash
    blk2 = annex &&& taprootPath
    blk3 = (((primitive CurrentValue &&& (primitive Version &&& primitive LockTime)) &&&
            (primitive CurrentIndex &&& scribe (toWord32 (2^31))) &&& zero word64))
       &&& scribe (toWord256 (512+2*512+64+3*32))
  hashAllCMR = fstProduct hashAllProduct
  lib@Lib{..} =
   Lib
    { hashAll = sndProduct hashAllProduct
    , sigHashAll =
       let
        iv = toWord256 . integerHash256 . ivHash $ signatureTag
        cmr = toWord256 . integerHash256 $ commitmentRoot hashAllCMR
        hb = sndProduct hashBlock
       in
            (scribe iv &&& (scribe cmr &&& hashAll) >>> hb)
         &&& scribe (toWord512 0x80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400)
         >>> hb
    }

-- | An instance of the Bitcoin signature hash 'Lib' library.
-- This instance does not share its dependencies.
-- Users should prefer to use 'mkLib' in order to share library dependencies.
-- This instance is provided mostly for testing purposes.
lib :: (Core term, Primitive term) => Lib term
lib = mkLib libSha256
 where
  libSha256 = Sha256.lib

-- | Given a public key and a bip0340 signature, this Simplicity program asserts that the signature is valid for the public key and the message generated by 'sigHashAll'.
-- The signature is in a 'witness' combinator and is not commited by the 'commitmentRoot' of this program.
checkSigHashAll :: (Assert term, Primitive term, Witness term) => LibSecp256k1.Lib term -- ^ "Simplicity.Programs.LibSecp256k1"
                                                               -> Lib term
                                                               -> Schnorr.PubKey -> Schnorr.Sig -> term () ()
checkSigHashAll libsecp256k1 Lib{..} (Schnorr.PubKey x) ~(Schnorr.Sig r s) =
   (scribe (toWord256 . toInteger $ x) &&& sigHashAll) &&& (witness (toWord256 . toInteger $ r, toWord256 . toInteger $ s))
   >>> bip_0340_verify
 where
  bip_0340_verify = LibSecp256k1.bip_0340_verify libsecp256k1
