type t

(* [create dir] is an instance of the full blockchain tree backed
 * by the LevelDB database in directory [dir]. If no database exists at
 * [dir] an new one is initialized. *)
val create : string -> P2p.t -> t Lwt.t

(* [best_chain b] is a longest chain of [b]. If two chains are equally long,
 * it is unspecified which will be returned. *)
val sync : t ref -> unit Lwt.t

val push_block : t ref -> Block.t -> unit Lwt.t

val head : t -> string

val next_block : t -> Block.t Lwt.t
