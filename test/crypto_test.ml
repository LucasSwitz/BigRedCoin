open Crypto
open OUnit2

let hex_cmp hex bytes =
  `Hex hex = Hex.of_string bytes

(* Tests for ECDSA. All tests are based on results derived from the OpenSSL library *)

let (hexpriv, hexpub) = "3b6db2dda246f4f3d1a42537075713a37b5a2911df041e6d2dc17a924c95db90", "6e50edd47c522bae7e2e83328f3ec3574929466a"
let hexaddr = "6e50edd47c522bae7e2e83328f3ec3574929466a"

let (pubkey, privkey) = Crypto.ECDSA.create ()
let testsig = ECDSA.sign (pubkey, privkey) "hello world"
let cmp_sig x y = ECDSA.string_of_sig x = ECDSA.string_of_sig y

let opt_exn = function | Some x -> x | None -> failwith "Unexpected None"

let ecdsa_tests =
  "ECDSA Tests" >::: [
    "sign_msg" >:: (fun _ -> assert_bool "Verify signature" (ECDSA.verify (ECDSA.to_address pubkey) "hello world" (ECDSA.sign (pubkey,privkey) "hello world")));
    "fake_msg" >:: (fun _ -> assert_bool "Fake signature"  @@ not (ECDSA.verify (ECDSA.to_address pubkey) "hello world" (ECDSA.sign (pubkey,privkey) "it's a trap!")));
    "hex" >:: (fun _ -> assert_equal hexpub (ECDSA.to_address (ECDSA.of_hex hexpriv |> fst)));
    "toaddr" >:: (fun _ -> assert_equal hexaddr (ECDSA.to_address (fst @@ ECDSA.of_hex hexpriv)));
    "sig_string" >:: (fun _ -> assert_equal ~cmp:cmp_sig testsig (testsig |> ECDSA.string_of_sig |> ECDSA.sig_of_string |> opt_exn));
    "bad_sig" >:: (fun _ -> assert_equal None (ECDSA.sig_of_string (String.make 65 '\xab')));
    "short_sig" >:: (fun _ -> assert_equal None (ECDSA.sig_of_string (String.make 60 '\xab')));
    "zero_prv" >:: (fun _ -> assert_raises (Failure "Secret.of_bytes_exn") (fun () -> ECDSA.of_hex (String.make 64 '0')));
    "large_prv" >:: (fun _ -> assert_raises (Failure "Secret.of_bytes_exn") (fun () -> ECDSA.of_hex (String.make 64 'F')));
  ]


(* Tests for AES and Scrypt *)

let keypair = ECDSA.create ()
let enc = AES.encrypt keypair "password"
let bad_enc = AES.of_string "{\"address\":\"8a8f43d5b15d29c1b198b088c2648f29bee144fd\",\"IV\":\"cd88005dbdb4d3100de04980c47f89a3\",\"salt\":\"91f39c3c9907557fffbd45871af3bd4d1aedd38a61ec946046cb278346195d28\",\"private key\":\"81ebb1e416ff1dafe27de13c3e26502037515b594be2ec490b8fb444a94b3ed5\"}" |> opt_exn

let aes_tests =
  "AES Tests" >::: [
    "enc/dec" >:: (fun _ -> assert_equal keypair (opt_exn (AES.decrypt enc "password")));
    "decrypt_failure" >:: (fun _ -> assert_equal None (AES.decrypt enc "password123"));
    "stringify" >:: (fun _ -> assert_equal keypair (enc |> AES.to_string |> AES.of_string |> opt_exn |> fun x -> AES.decrypt x "password" |> opt_exn));
    "address" >:: (fun _ -> assert_equal (ECDSA.to_address (fst keypair)) (AES.address enc));
    "bad_decrypt" >:: (fun _ -> assert_equal None (AES.decrypt bad_enc "password"))
]

let sha256test = "sha256" >:: (fun _ -> assert_equal ~cmp:hex_cmp "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9" (Crypto.sha256 "hello world"))

let tests = "Crypto Tests" >::: [ecdsa_tests; aes_tests; sha256test]
