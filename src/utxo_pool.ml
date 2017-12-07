open Transaction
open Block
module TransactionDB = Database.Make(Transaction)

exception Invalid_block

let output_hash tx_id output_index =
  Crypto.sha256 (tx_id^(string_of_int output_index))

module UTXO = struct
  type t = Transaction.input
  let compare = compare
end

module UTXOMap = Map.Make(UTXO)

type t = {pool : Transaction.output UTXOMap.t; db : TransactionDB.t}

let empty db = {pool = UTXOMap.empty; db}


let revert_transaction {pool; db} transaction =
  let trans_hash = Transaction.hash transaction in
  let removed = List.fold_left (fun (acc,index) output ->
      let utxo = {txid = trans_hash; out_index = index} in
      (UTXOMap.remove utxo acc,index+1)
    ) (pool,0) transaction.outs
  in
  let%lwt readded_inputs =
    let add_output acc input =
      let%lwt old_transaction = TransactionDB.get db input.txid in
      let old_output = List.nth old_transaction.outs input.out_index in
      Lwt.return @@ UTXOMap.add input old_output acc
    in
    Lwt_list.fold_left_s add_output (fst removed) transaction.ins
  in
  Lwt.return {pool = readded_inputs; db}

let put_transaction tm transaction =
  let removed =
    List.fold_left (fun acc input ->
        (UTXOMap.remove input acc)
      ) tm transaction.ins
  in
  let txid = Transaction.hash transaction in
  let added = List.fold_left (fun (acc,out_index) output ->
      (UTXOMap.add {txid; out_index} output acc, out_index+1)
    ) (removed,0) transaction.outs
  in
  fst added

(*verify inputs exist*)
let verify transaction = failwith "Unimplemented"
  (*let out_totals = List.fold_left (fun acc e -> e.amount) 0 transaction.outs in 
  let in_totals = List.map(fun in -> ) [] transaction.ins

  match (Transaction.signers transaction) with
  | None ->  false
  | Some signers ->
    List.for_all(fun output -> (List.mem output.address signers)) transaction.outs*)

let revert p (b:Block.t) =
  let transactions = b.transactions in
  let%lwt pool = Lwt_list.fold_left_s revert_transaction p transactions in
  Lwt.return pool

let apply {pool; db} block =
  Lwt_list.iter_p (TransactionDB.put db) block.transactions >>
  if (List.for_all verify block.transactions) then
    Lwt.return
     {db; pool = List.fold_left put_transaction pool block.transactions}
  else
    raise Invalid_block


let filter {pool; _} addr =
  UTXOMap.filter (fun input {address; _} -> address = addr) pool
  |> UTXOMap.bindings
