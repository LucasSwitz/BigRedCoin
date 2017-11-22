open Lwt
open Csv_lwt
open Message_types

exception FailedToConnect of string

let c_MAX_CONNECTIONS = 1024

module type Message_channel = sig
  (* The type of an input message channel. *)
  type input

  (* The type of an output message channel. *)
  type output

  (* [write o m] writes the message [m] to the given output channel [o]. *)
  val write : output -> Message_types.message -> int Lwt.t

  (* [read i] reads a message from the given input channel [i]. *)
  val read : input -> Message_types.message option Lwt.t

  val close_in : input -> unit Lwt.t

  val close_out : output -> unit Lwt.t
end

module BRCMessage_channel : Message_channel with
  type input = Lwt_io.input Lwt_io.channel and
  type output = Lwt_io.output Lwt_io.channel
  = struct

  type input = Lwt_io.input Lwt_io.channel

  type output = Lwt_io.output Lwt_io.channel
  let write oc msg =
    let encoder = Pbrt.Encoder.create() in
    Message_pb.encode_message msg encoder;
    let buf = Pbrt.Encoder.to_bytes encoder in
    let%lwt bytes_written = Lwt_io.write_from oc buf 0 (Bytes.length buf) in
    Lwt.return bytes_written

  let read_raw_msg ic =
    let timeout = Lwt_unix.sleep 1. >> Lwt.return (0,Bytes.empty) in
    let buf = Bytes.create 2048 in
    let read =
      let%lwt sz = Lwt_io.read_into ic buf 0 2048 in Lwt.return(sz,buf) in
    Lwt.pick[timeout;read]

  let read ic =
    match%lwt read_raw_msg ic with
    | (0,_) -> Lwt.return_none
    | (_,buf) ->
      Lwt.return_some (Message_pb.decode_message (Pbrt.Decoder.of_bytes buf))

  let close_in ic =
    Lwt_log.notice "Closing input channel" >>
    Lwt_io.close ic

  let close_out oc =
    Lwt_log.notice "Closing output channel" >>
    Lwt_io.close oc
end

module type BRCPeer_t = sig
  type peer_connection
  type peer
  val null_peer : unit -> peer
  val addr : peer -> Unix.sockaddr
  val s_addr : peer -> string
  val str : peer_connection -> string
  val ic : peer_connection -> BRCMessage_channel.input
  val oc : peer_connection -> BRCMessage_channel.output
end

module BRCPeer = struct

  type peer_connection = {
    addr: Unix.sockaddr;
    ic: BRCMessage_channel.input;
    oc: BRCMessage_channel.output;
  }

  type peer = Message_types.peer
  let null_peer () = {
    address = "";
    port = 0;
    last_seen = 0;
  }
  let (<=>) p1 p2 =
    p1.address = p2.address && p1.port = p2.port
  let addr peer = Unix.(ADDR_INET (inet_addr_of_string peer.address, peer.port))
  let s_addr peer = peer.address ^ ":" ^ (string_of_int peer.port)
  let socket_addr_to_string addr =
    match addr with
    | Lwt_unix.ADDR_UNIX addr -> addr
    | Lwt_unix.ADDR_INET (addr,port) ->
      (Unix.string_of_inet_addr addr) ^ ":" ^ (string_of_int port)
  let str conn = socket_addr_to_string conn.addr
  let ic conn = conn.ic
  let oc conn = conn.oc
end

open BRCPeer

module type PeerList_t = sig
  type item
  type t
  val find: item -> t -> int option
  val remove: int -> t -> t
  val update: int -> item -> t -> t
  val modify: item -> t -> t
  val append: item -> t -> t
end

module PeerList = struct
  include Array

  type item = peer
  type t = item array

  let find item arr =
    let (found, i) = fold_left
            (fun (found, index) a ->
               if item <=> a then (true, index)
               else (false, index+1)) (false,0) arr in
    if found then Some i else None

  let remove i arr =
    let new_arr = make ((Array.length arr)-1) (null_peer ()) in
    iteri (fun pos item ->
        if pos < i then new_arr.(pos) <- arr.(pos)
        else if pos > i then new_arr.(pos-1) <- arr.(pos)
        else ()) arr;
    new_arr

  let update i item arr =
    arr.(i) <- item; arr

  let modify item arr =
    iteri (fun i a -> if a <=> item then arr.(i) <- item else ()) arr; arr

  let append item arr =
    Array.append [|item|] arr
end

module PeerTbl = struct
  include Hashtbl
  let remove tbl addr =
    match find_opt tbl addr with
    | Some peer -> remove tbl addr;
      BRCMessage_channel.close_in peer.ic >>
      BRCMessage_channel.close_out peer.oc
    | None -> Lwt.return_unit

  let add tbl peer =
    remove tbl (str peer) >>
    Lwt.return @@ add tbl (str peer) peer
end

type t = {
  connections:(string,peer_connection) PeerTbl.t;
  handled_connections:(string,peer_connection) Hashtbl.t;
  mutable known_peers: PeerList.t;
  server:Lwt_io.server option;
  port:int;
  peer_file:string}

let id p2p =
  string_of_int p2p.port

let remove_known_peer p2p addr =
  match PeerList.find addr p2p.known_peers with
  | Some i -> p2p.known_peers <- PeerList.remove i p2p.known_peers
  | None -> ()

let remove_handle_connection p2p peer =
  Hashtbl.remove p2p.handled_connections (str peer);
  Lwt.return_unit

let close_peer_connection p2p (peer:peer_connection) =
  PeerTbl.remove p2p.connections (str peer)

let handle f p2p peer  =
  Hashtbl.add p2p.handled_connections (str peer) peer;
  let%lwt (close,res) = f peer in
  if close then
    close_peer_connection p2p peer >> res
  else
    remove_handle_connection p2p peer >> res

let (@<>) (p2p,peer) f =
  handle f p2p peer

let is_peer_open inet p2p =
  PeerTbl.mem p2p.connections inet

let get_connected_peer inet p2p =
  PeerTbl.find p2p.connections inet

let decode_message bytes =
  (Message_pb.decode_message (Pbrt.Decoder.of_bytes bytes))

let encode_message bytes =
  let encoder = Pbrt.Encoder.create() in
  Message_pb.encode_message bytes encoder;
  Pbrt.Encoder.to_bytes encoder

let initiate_connection peer_addr =
  Lwt.catch (
      fun () -> let%lwt (ic, oc)  = Lwt_io.open_connection peer_addr in
        Lwt.return_some {addr=peer_addr;ic=ic;oc=oc})
      (fun e -> Lwt.return_none)

let connect_to_peer peer p2p =
  let target = (s_addr peer) in
  if (is_peer_open target p2p) then
    let peer = (get_connected_peer target p2p) in
    Lwt.return_some peer
  else
    let addr = Unix.(ADDR_INET (Unix.inet_addr_of_string peer.address, peer.port)) in
    Lwt_log.notice ((id p2p) ^ ": Attempting to initiate connection: " ^ socket_addr_to_string addr) >>
      match%lwt initiate_connection addr with
      | Some conn ->
        let mod_peer = {peer with last_seen = int_of_float (Unix.time ())} in
        p2p.known_peers <- PeerList.modify mod_peer p2p.known_peers;
        PeerTbl.add p2p.connections conn
        >> Lwt.return_some conn
      | None -> Lwt.return_none

let read_for_time conn time =
  let timeout = Lwt_unix.sleep time >> Lwt.return None in
  let read = BRCMessage_channel.read conn in
  match%lwt Lwt.pick[read;timeout] with
  | Some msg -> Lwt.return_some msg
  | None -> Lwt.return_none

let rec send_till_success conn msg =
  let%lwt bytes_sent = BRCMessage_channel.write conn.oc msg in
  if bytes_sent = 0 then
    send_till_success conn msg
  else
    Lwt.return_some ()

let connect_and_send peer msg p2p =
  match%lwt connect_to_peer peer p2p with
  | Some conn ->
    let timeout = Lwt_unix.sleep 2.0 >> Lwt.return None in
    (match%lwt Lwt.pick [timeout;(send_till_success conn msg)] with
     | Some _ -> Lwt_log.notice ((id p2p) ^ ": Wrote Message to: " ^ (str conn))
     | None -> Lwt_log.notice ((id p2p) ^ ": Failed to send message to: " ^ (str conn)))
  | None -> Lwt.return_unit
let send_raw bytes size oc =
  Lwt_io.write_from_exactly oc bytes 0 size

let broadcast (msg:Message_types.message) (p2p:t) =
  PeerList.fold_left (fun acc peer ->
      (connect_and_send peer msg p2p)<&>acc)
    Lwt.return_unit p2p.known_peers

let handle_new_peer_connection p2p addr (ic,oc) =
  if (Hashtbl.length p2p.connections < c_MAX_CONNECTIONS) then
    Lwt_log.notice((id p2p) ^ ": Got new peer @ " ^ socket_addr_to_string addr) >>
    let conn = { addr = addr; ic = ic; oc = oc} in
    match%lwt read_for_time (BRCPeer.ic conn) 2. with
    | Some msg ->
      (match msg.frame_type with
      | Peer -> failwith "handle peer data"
      | Data -> PeerTbl.add p2p.connections conn
      )
    | None -> Lwt_log.notice((id p2p) ^ ": Failed to retrieve preamble.")
  else
    BRCMessage_channel.close_in ic >> BRCMessage_channel.close_out oc

let rec connect_to_a_peer p2p ?peers:(peers=p2p.known_peers) () =
  if PeerList.length peers = 0 then
    Lwt.return_none
  else
    let random = Random.int (PeerList.length peers) in
    let peer = peers.(random) in
    let target_addr = s_addr peer in
    if (is_peer_open target_addr p2p) then
      let peer_connection = get_connected_peer target_addr p2p in
      Lwt.return_some peer_connection
    else
      let timeout = Lwt_unix.sleep 2. >> Lwt.return_none in
      let conn_thread = connect_to_peer peer p2p in
      match%lwt Lwt.pick [timeout;conn_thread] with
      | Some peer -> Lwt.return_some peer
      | None ->
        let good_peer_lst = PeerList.remove random peers in
        connect_to_a_peer p2p ~peers:good_peer_lst ()

let tbl_to_list tbl =
  Hashtbl.fold ( fun _ peer lst -> peer::lst) tbl []

let known_peer_stream p2p =
  Lwt_stream.from(connect_to_a_peer p2p)

let unhandled_connected_peer_stream p2p =
  let unhandled = Hashtbl.copy p2p.connections in
  Hashtbl.filter_map_inplace(
    fun addr peer ->
      if (Hashtbl.mem p2p.handled_connections addr) then
        None
      else
        Some peer
  ) unhandled;
  Lwt_stream.of_list(tbl_to_list unhandled)

let peer_stream p2p =
  Lwt_stream.append (unhandled_connected_peer_stream p2p) (known_peer_stream p2p)

let start_server port p2p =
  let port = Unix.(ADDR_INET (inet_addr_loopback,port)) in
  let%lwt server =
    Lwt_io.establish_server_with_client_address ~no_close:true port
      (p2p |> handle_new_peer_connection)
  in
  Lwt.return (server)

let shutdown p2p =
  match p2p.server with
  | Some server -> Lwt_io.shutdown_server server
  | None -> Lwt.return_unit

let add_new_peer addr_port p2p =
  p2p.known_peers <- PeerList.append addr_port p2p.known_peers

let server_port p2p =
  p2p.port

let create_from_list ?port:(p=4000) (peer_list:(string * int * (Unix.tm option)) list) =
  let peers = Array.of_list (List.map
    (fun (i,p,tm) ->
      let time = match tm with None -> 0. | Some a -> (fst (Unix.mktime a)) in
       {
         address = i;
         port = p;
         last_seen = int_of_float time
       })
    peer_list) in
  let p2p = {
    server= None;
    port = p;
    handled_connections = Hashtbl.create 20;
    connections= (PeerTbl.create 20);
    known_peers= peers;
    peer_file = "nodes/brc" ^ (string_of_int p) ^ ".peers";
  } in
  let%lwt server = start_server p p2p in
  Lwt.return {p2p with server = (Some server);port=p}

let string_of_tm (tm:Unix.tm) =
  Unix.(Printf.sprintf "%02d:%02d:%02d %02d/%02d/%04d"
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
    (tm.tm_mon+1)
    tm.tm_mday
    (tm.tm_year + 1900))

let tm_of_string s =
  try
    Scanf.sscanf s "%02d:%02d:%02d %02d/%02d/%04d"
      (fun h m s mo d y -> Unix.(snd (mktime
          {
            tm_sec=s; tm_min=m; tm_hour=h;
            tm_mday=d; tm_mon=mo-1; tm_year=y-1900;
            tm_wday=0; tm_yday=0; tm_isdst=false
          })))
  with
  | Scanf.Scan_failure _
  | End_of_file
  | Unix.Unix_error (Unix.ERANGE, "mktime", _) ->
    Unix.localtime 0.

let csv_of_peer peer =
  [
    peer.address;
    string_of_int peer.port;
    string_of_tm (Unix.localtime (float_of_int peer.last_seen))
  ]

let peer_of_csv s =
  let (time,_) = Unix.mktime (tm_of_string (List.nth s 2)) in
  {
    address = List.nth s 0;
    port = int_of_string (List.nth s 1);
    last_seen = int_of_float time;
  }

let peer_cmp p1 p2 =
  if p1.last_seen > p2.last_seen then -1
  else if p1.last_seen = p2.last_seen then 0
  else 1

let save_peers f p2p =
  PeerList.sort peer_cmp p2p.known_peers;
  let csv = PeerList.map (fun p -> csv_of_peer p) p2p.known_peers in
  Csv_lwt.save f (PeerList.to_list csv)

let load_peers f =
  let%lwt csv = Csv_lwt.load f in
  Lwt.return @@ PeerList.of_list (List.map (fun s -> peer_of_csv s) csv)

let create ?port:(p=4000) peer_file =
  let%lwt peers = load_peers peer_file in
  let p2p = {
    server= None;
    port = p;
    handled_connections = Hashtbl.create 20;
    connections= (PeerTbl.create 20);
    known_peers= peers;
    peer_file = peer_file;
  } in
  let%lwt server = start_server p p2p in
  Lwt.return {p2p with server = (Some server)}

let shutdown p2p =
  Hashtbl.fold (fun _ a _ -> ignore (close_peer_connection p2p a)) (p2p.connections) ();
  save_peers p2p.peer_file p2p >>
  match p2p.server with
  | Some server -> Lwt_io.shutdown_server server
  | None -> Lwt.return_unit
