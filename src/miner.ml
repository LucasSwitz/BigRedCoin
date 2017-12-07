open Lwt
open Block
open Transaction
(* A t is a miner with a push stream of blocks in push, and a list of mining
 * process ids with a read pipe and a write pipe. *)
type t = {
  blockchain : Blockchain.t ref;
  push : Block.t option -> unit;
  mutable mining : bool;
  address : string
}

let create addr f chain =
  {push = f; blockchain = chain; mining = false; address = addr}

(* [equiv block1 block2] is true if [block1] equals [block2] in all fields but
 * the header's nonce and timestamp. 
 * requires: block1 and block2 both have a nonempty transaction. *)
let equiv block1 block2 =
  block1.header.version = block2.header.version 
  && block1.header.merkle_root = block2.header.merkle_root
  && block1.header.prev_hash = block2.header.prev_hash
  && block1.header.nBits = block2.header.nBits
  && block1.transactions_count = block2.transactions_count
  && List.tl block1.transactions = List.tl block2.transactions

(* [mine p] attempts to mine blocks sourced from [t]'s blockchain and pushes
 * blocks with low enough hash to [t]'s push stream. The next block to be 
 * mined is in [p]. *)
let rec mine t prev =
  if t.mining = false then (Lwt.return ())
  else begin
    Lwt_main.yield () >>
    Blockchain.next_block !(t.blockchain) >>= fun b ->
      let b = {b with transactions = {
          ins = [];
          outs = [{amount = 25; address = t.address}];
          sigs = Some [Crypto.random 256]
        }::b.transactions
      } in
      match prev with
        | Some block -> begin 
            if equiv b block then
              let next = Some Block.{block with
                Block.header = {block.header with
                  Block.timestamp = int_of_float (Unix.time ()); 
                  nonce = block.header.nonce + 1 mod 2147483647
                }
              } in
              if Block.hash block < Block.target block.header.nBits then 
                Lwt.return (t.push (Some block))
              else mine t next
            else
              let y = Some Block.{b with
                Block.header = {b.header with
                  Block.timestamp = int_of_float (Unix.time ());
                  nonce = Random.int 217483647
                }
              } in
              mine t y
            end
        | None -> mine t (Some b)
  end

let start t =
  t.mining <- true;
  mine t None

let stop t =
  t.mining <- false
