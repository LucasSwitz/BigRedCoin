(* The header of a block in the chain. Version is the version of the protocol.
 * The prev_hash is the hash of the previous block. The merkle_root is the
 * root of this block in the merkle_tree. The nonce is as in the proof of work
 * algorithm. nBits is a compressed version of the mining difficulty. The 
 * timestamp is the seconds since the unix epoch when the block was made. *)
type header = {
  version : int;
  prev_hash : string;
  merkle_root : string;
  nonce : int;
  nBits : int;
  timestamp : int
}

(* A block consists of its header, the transactions in the block, and a count
 * of the number of transactions in the block. *)
type block = {
  header : header;
  transactions : Transaction.t list;
  transactions_count : int
}

type t = block

val target_block_time : int

val blocks_per_recalculation : int

(* [target nbits] is the decompressed target that [nbits] represents. *)
val target : int -> string

(* [difficulty nbits] is the "reciprocal" of the target, a measure of the 
 * proportion of the maximum possible difficulty. *)
val difficulty : int -> int

(* [next_target header] is the compressed form of the target for the next block,
 * given the timestamp and difficulty of the previous block. *)
val next_difficulty : header -> header -> int

(* [insert_transaction b tx] is [b] with the additional transaction [tx]*)
val insert_transaction : t -> Transaction.t -> t

(* [block h] is the hash of the header of the block [b]. *)
val hash : t -> string

(* [serialize b] is a serialized representation of a block [b]. *)
val serialize : t -> string

(* [deserialize s] is the block [b] with [serialize b] = [s]. *)
val deserialize : string -> t

val messageify : t -> Message_types.block

val demessageify : Message_types.block -> t

