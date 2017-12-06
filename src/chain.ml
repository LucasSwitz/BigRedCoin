open Block
open Lwt

module BlockDB = Database.Make(Block)
module Cache = Map.Make(String)

let cache_size = 2048

type t = {hash : string;
          head : Block.t;
          height : int;
          cache : (int * Block.t) Cache.t;
          db : BlockDB.t}

let block_at_index {hash; head; height; cache; db} (n : int) =
  let nth_opt =
    List.find_opt (fun (_, (i,_)) -> i = n) (Cache.bindings cache)
  in
  match nth_opt with
  | Some (_, (_, block)) -> Lwt.return block
  | None ->
    let rec parent block n =
      if n = 0 then Lwt.return block else
      let%lwt p = BlockDB.get db Block.(block.header.prev_hash) in
      parent p (n - 1)
    in
    parent head (height - n)

let next_difficulty  ({hash; head; height; cache; _} as chain) =
  if height + 1 mod 2016 = 0 then
    let adjustment_block = height - 2016 in
    let%lwt reference = block_at_index chain adjustment_block in
    let nbits' = Block.(next_difficulty head.header reference.header) in
    Lwt.return nbits'
  else
    Lwt.return head.header.nBits

(* doesn't validate txs yet *)
let extend ({hash; head; height; cache; _} as chain) new_block =
  let%lwt nbits' = next_difficulty chain in
  let target = Block.target nbits' in
  let blockhash = Block.hash new_block  in
  if blockhash > target ||
     new_block.header.nBits <> nbits' ||
     new_block.header.prev_hash <> hash
  then
    Lwt.return_none
  else
    let cache' = Cache.add blockhash (height+1, new_block) cache in
    let cache' = Cache.filter (fun _ (i, _) -> height - i <= 2048) cache' in
    Lwt.return_some
      { chain with
        hash = blockhash;
        head = new_block;
        height = height + 1;
        cache = cache';
      }

(* [extend_cache chain] represents the same chain of blocks as [chain], but with a
 * cache extending 25 blocks further into the past. *)
let extend_cache {cache; db; _} =
  let no_parent h =
    let (_, {header;_}) = Cache.find h cache in
    not (Cache.mem header.prev_hash cache)
  in
  let (_, oldest) = Cache.find_first no_parent cache in
  let rec add_parent cache (height, child) n =
    if n = 0 then Lwt.return cache
    else
      let%lwt parent = BlockDB.get db child.header.prev_hash in
      let cache' = Cache.add child.header.prev_hash (height - 1, parent) cache in
      add_parent cache' (height - 1, parent) (n-1)
  in
  add_parent cache oldest 25

let rec shared_root c1 c2 =
  let highest_block h (i,b) acc =
    match Cache.find_opt h c2.cache, acc with
    | None, _ -> acc
    | Some x, None -> Some x
    | Some (height, block), Some (height', block') ->
      begin
        if height' > height
        then Some (height', block')
        else Some (height, block)
      end
  in
  match Cache.fold highest_block c1.cache None with
  | Some (i, b) -> Lwt.return b
  | None ->
    let%lwt c1' = extend_cache c1 in
    let%lwt c2' = extend_cache c2 in
    shared_root c1 c2

let rec revert ({hash; head; height; cache; db} as c) h =
  if hash = h
  then ([], {c with cache = Cache.empty})
  else
    let prev_hash = head.header.prev_hash in
    let _, parent = Cache.find prev_hash cache in
    let (blocks, chain) = revert {c with head = parent;
                                         hash = prev_hash;
                                         height = (height-1)
                                 } h
    in
    head::blocks, chain

let head {head; _} = head
let height {height; _} = height
let hash {hash; _ } = hash

let create db block =
  let hash = Block.hash block in
  let cache = Cache.add hash (0,block) Cache.empty in
  {head = block;
   hash;
   height = 0;
   cache;
   db}

(*Format: 8 byte height of chain in big-endian, then 32 byte hash of head block *)
let serialize {hash; height; _} =
  let height_str =
    let int_buf = Cstruct.create 8 in
    Cstruct.BE.set_uint64 int_buf 0 (Int64.of_int height);
    Cstruct.to_string int_buf
  in
  height_str ^ hash

(* [deserialize (serialize chain)] represents the same chain as chain,
 * but with a fresh cache of size 25 *)
let deserialize db s =
  let buf = Cstruct.of_string s in
  let height = Cstruct.BE.get_uint64 buf 0 |> Int64.to_int in
  let hash = Cstruct.copy buf 8 32 in
  let%lwt head = BlockDB.get db hash in
  let cache = Cache.add hash (height, head) Cache.empty in
  let chain = {height; hash; head; cache; db} in
  let%lwt cache' = extend_cache chain in
  Lwt.return {chain with cache = cache'}
