(* The output of a transaction. Amount is how much is sent to an address and
 * address is the recipient of a transaction. *)
type output = {
  amount: int;
  address : string
}

(* The input to a transaction. txid is the SHA-256 hash of the transaction the
 * input comes from and out_index is the index of the input. The signature is
 * the ECDSA signature of the hash of the transaction id, out_index, and list
 * of outputs from the transaction.*)
type input = {
  txid : string;
  out_index : int;
}

(* A transaction is a list of outputs to which coins are sent and a list of
 * inputs from which coins originate. The sum of the amounts in the outputs
 * linked to the inputs must sum to the sum of the outputs of this transaction.
 * *)
type t = {
  outs : output list;
  ins : input list;
  sigs : string list option
}

(* [messageify t] is [t] turned into a protobuf message. *)
val messageify : t -> Message_types.transaction 

(* [serialize t] is the protobuf encoding of [i] as a string
 * Does not include signature information. The hash of this encoding is the txid.
 * All signatures should be of this as serialization. *)
val serialize : t -> string

(* [messageify m] is the protobuf message representing a transaction [m] turned
 * into a record. *)
val demessageify : Message_types.transaction -> t

(* [deserialize s] is [tx] where [serialize tx = s] *)
val deserialize : string -> t

(* [hash t] uniquely identifies the transaction [t] *)
val hash : t -> string

(* [signers tx] is the list [a_1; a_2; ...; a_n] where a_i is the address of
 * the public key which signed the ith transaction input in [tx]
 * Returns [None] if any signature is invalid *)
val signers : t -> string list option

(* [merkle_root [tx1; ...; txn]] is the root of the binary tree generated by
 * pairwise hashing the transactions. *)
val merkle_root : t list -> string
