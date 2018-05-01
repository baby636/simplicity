Require Import ZArith.
Require Import String.
Require Import Util.List.
Require Import compcert.lib.Integers.
Global Unset Asymmetric Patterns. (* the VST library does a Global Set so we must unset it. *)

Require Import Simplicity.Digest.
Require Simplicity.MerkleRoot.
Require Import Simplicity.Primitive.
Require Import Simplicity.Ty.
Require Import Simplicity.SHA256.
Require Import Simplicity.Word.

Set Primitive Projections.
Set Implicit Arguments.

Import ListNotations.

Section DataTypes.

Definition MAX_MONEY : Z := 21000000 * 10^8.
Notation moneyRange x := (-1 < x < Z.succ MAX_MONEY)%Z.

Definition lock := int.
Definition script := list byte.

Record outpoint : Set :=
 { opHash : hash256
 ; opIndex : int
 }.

Record sigTxInput : Set :=
 { sigTxiPreviousOutpoint : outpoint
 ; sigTxiValue : int64
 ; sigTxiSequence : int
 ; sigTxiValue_bound : moneyRange (Int64.signed sigTxiValue)
 }.

Record txOutput : Set :=
 { txoValue : int64
 ; txoScript : script
 ; txoValue_bound : moneyRange (Int64.signed txoValue)
 ; txoScript_bound : (Zlength txoScript < Int.modulus)%Z
 }.

Record sigTx : Set :=
 { sigTxVersion : int
 ; sigTxIn : list sigTxInput
 ; sigTxOut : list txOutput
 ; sigTxLock : lock
 ; sigTxInBounds : (0 < Zlength sigTxIn < Z.succ Int64.modulus)%Z
 ; sigTxOutBounds : (0 < Zlength sigTxOut < Z.succ Int.modulus)%Z
 ; sigTxTotalInValue : Z := Z_sum (map (fun i => Int64.signed (sigTxiValue i)) sigTxIn)
 ; sigTxTotalOutValue : Z := Z_sum (map (fun i => Int64.signed (txoValue i)) sigTxOut)
 ; sigTxFee : Z := sigTxTotalOutValue - sigTxTotalInValue
 ; sigTxTotalInValue_bound : moneyRange sigTxTotalInValue
 ; sigTxTotalOutValue_bound : moneyRange sigTxTotalOutValue
 ; sigTxFee_bound : moneyRange sigTxFee
 }.

End DataTypes.

Section Serialization.

Definition putHash256le (x : hash256) : list byte :=
  map Byte.repr (hash256_to_Zlist x).

Definition putInt64le (x : Int64.int) : list byte :=
let z := Int64.unsigned x in
map (fun i => Byte.repr (z / two_power_nat (i*Byte.wordsize))%Z) (seq 0 8).

Definition putInt32le (x : Int.int) : list byte :=
let z := Int.unsigned x in
map (fun i => Byte.repr (z / two_power_nat (i*Byte.wordsize))%Z) (seq 0 4).

Definition putVarInt (x : Int64.int) : list byte :=
let z := Int64.unsigned x in
  if (Z_lt_le_dec z 253)
  then [ Byte.repr z ]
  else if (Z_lt_le_dec z (two_power_nat 16))
  then Byte.repr 253 :: map (fun i => Byte.repr (z / two_power_nat (i*Byte.wordsize))%Z) (seq 0 2)
  else if (Z_lt_le_dec z Int.modulus)
  then Byte.repr 254 :: putInt32le (Int.repr z)
  else Byte.repr 255 :: putInt64le (Int64.repr z).

Definition putScript (x : script) : list byte :=
let z := Int64.repr (Zlength x) in
    putVarInt z ++ x.

Definition putOutpoint (x : outpoint) : list byte :=
    putHash256le (opHash x)
 ++ putInt32le (opIndex x).

Definition putTxOutput (x : txOutput) : list byte :=
    putInt64le (txoValue x)
 ++ putScript (txoScript x).

End Serialization.

Module Bitcoin <: PrimitiveSig.

Inductive prim : Ty -> Ty -> Set :=
| Version : prim Unit Word32
| LockTime : prim Unit Word32
| InputsHash : prim Unit Word256
| OutputsHash : prim Unit Word256
| MaxInput : prim Unit Word64
| TotalInputValue : prim Unit Word64
| CurrentPrevOutpoint : prim Unit (Prod Word256 Word32)
| CurrentValue : prim Unit Word64
| CurrentSequence : prim Unit Word32
| CurrentIndex : prim Unit Word64
| InputPrevOutpoint : prim Word64 (Sum Unit (Prod Word256 Word32))
| InputValue : prim Word64 (Sum Unit Word64)
| InputSequence : prim Word64 (Sum Unit Word32)
| MaxOutput : prim Unit Word32
| TotalOutputValue : prim Unit Word64
| OutputValue : prim Word32 (Sum Unit Word64)
| OutputScriptHash : prim Word32 (Sum Unit Word256)
| ScirptCMR : prim Unit Word256.
Definition t := prim.

Definition primName : string := "Bitcoin".

Definition name {a b} (p : t a b) : string :=
match p with
| Version => "version"
| LockTime => "locktime"
| InputsHash => "inputsHash"
| OutputsHash => "outputsHash"
| MaxInput => "maxInput"
| TotalInputValue => "totalInputValue"
| CurrentPrevOutpoint => "currentPrevOutpoint"
| CurrentValue => "currentValue"
| CurrentSequence => "currentSequence"
| CurrentIndex => "currentIndex"
| InputPrevOutpoint => "inputPrevOutpoint"
| InputValue => "inputValue"
| InputSequence => "inputSequence"
| MaxOutput => "maxOutput"
| TotalOutputValue => "totalOutputValue"
| OutputValue => "outputValue"
| OutputScriptHash => "outputScriptHash"
| ScriptCMR => "scriptCMR"
end.

Section Tag.

Let tag_def {A B} (p : t A B) : hash256.
pose (nm := name p).
revert p nm; intros [] nm;
exact (MerkleRoot.tag (primitivePrefix primName ++ [nm]) refl_equal).
Defined.

(* Using Eval vm_compute lets us precompute all the tags for all our primitives *)
Definition tag {A B} (p : t A B) := Eval vm_compute in (tag_def p).
(* Try running *)
(* Print tag.  *)

End Tag.

Record enviroment :=
{ envTx : sigTx
; envIx : nat
; envScriptCMR : hash256
; envIxBounded : envIx < length (sigTxIn envTx)
}.
Definition env := enviroment.

Section primSem.

Let cast {A : Ty} (x : option A) : tySem (Unit + A) :=
match x with
| Some a => inr a
| None => inl tt
end.

Let encodeOutpoint (op : outpoint) : tySem (Word256 * Word32) :=
 (repr_Hash_inv (opHash op), fromZ (Int.unsigned (opIndex op)) : Word32).

Definition sem (e : env) {A B} (p : t A B) : A -> option B :=
let tx := envTx e in
let ix := envIx e in
let currentInput {A : Ty} (f : sigTxInput -> A) := option_map f (nth_error (sigTxIn tx) ix) in
let atInput {A : Ty} (f : sigTxInput -> A) (i : Word64) :=
  Some (cast (option_map f (nth_error (sigTxIn tx) (Z.to_nat (toZ i))))) in
let atOutput {A : Ty} (f : txOutput -> A) (i : Word32) :=
  Some (cast (option_map f (nth_error (sigTxOut tx) (Z.to_nat (toZ i))))) in
let outputsHash := byteStringHash (concat (map putTxOutput (sigTxOut tx))) in
let inputsHash :=
  let go i := putOutpoint (sigTxiPreviousOutpoint i) ++ putInt32le (sigTxiSequence i) in
  byteStringHash (concat (map go (sigTxIn tx))) in
match p with
| Version => fun _ => Some (fromZ (Int.signed (sigTxVersion tx)))
| LockTime => fun _ => Some (fromZ (Int.unsigned (sigTxLock tx)))
| InputsHash => fun _ => Some (repr_Hash_inv inputsHash)
| OutputsHash => fun _ => Some (repr_Hash_inv outputsHash)
| MaxInput => fun _ => Some (fromZ (Zpred (Zlength (sigTxIn tx))))
| TotalInputValue => fun _ => Some (fromZ (sigTxTotalInValue tx))
| CurrentPrevOutpoint => fun _ => currentInput (fun txi => encodeOutpoint (sigTxiPreviousOutpoint txi))
| CurrentValue => fun _ => currentInput (fun txi => fromZ (Int64.signed (sigTxiValue txi)))
| CurrentSequence => fun _ => currentInput (fun txi => fromZ (Int.unsigned (sigTxiSequence txi)))
| CurrentIndex => fun _ => Some (fromZ (Z.of_nat ix))
| InputPrevOutpoint => atInput (fun txi => encodeOutpoint (sigTxiPreviousOutpoint txi))
| InputValue => atInput (fun txi => fromZ (Int64.signed (sigTxiValue txi)))
| InputSequence => atInput (fun txi => fromZ (Int.unsigned (sigTxiSequence txi)))
| MaxOutput => fun _ => Some (fromZ (Zpred (Zlength (sigTxOut tx))))
| TotalOutputValue => fun _ => Some (fromZ (sigTxTotalOutValue tx))
| OutputValue => atOutput (fun txout => fromZ (Int64.signed (txoValue txout)))
| OutputScriptHash => atOutput (fun txout => repr_Hash_inv (byteStringHash (txoScript txout)))
| ScriptCMR => fun _ => Some (repr_Hash_inv (envScriptCMR e))
end.

End primSem.

End Bitcoin.

Module PrimitiveBitcoin := Primitive Bitcoin.
Export PrimitiveBitcoin.Theory.