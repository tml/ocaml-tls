
open Lwt
open Ex_common

let serve_ssl port callback =

  let tag = "server" in

  lwt barcert =
    X509_lwt.private_of_pems
      ~cert:(ca_cert_dir ^ "/bar.pem")
      ~priv_key:server_key in

  lwt foocert =
    X509_lwt.private_of_pems
      ~cert:(ca_cert_dir ^ "/foo.pem")
      ~priv_key:server_key in

  let server_s =
    let open Lwt_unix in
    let s = socket PF_INET SOCK_STREAM 0 in
    bind s (ADDR_INET (Unix.inet_addr_any, port)) ;
    listen s 10 ;
    s in

  let handle ep channels addr =
    let host = match ep with
      | `Ok data -> ( match data.Tls.Engine.own_name with
          | Some n -> n
          | None   -> "no name" )
      | `Error   -> "no session"
    in
    async @@ fun () ->
      try_lwt
        callback host channels addr >> yap ~tag "<- handler done"
      with
      | Tls_lwt.Tls_alert a ->
          yap ~tag @@ "handler: " ^ Tls.Packet.alert_type_to_string a
      | exn -> yap ~tag "handler: exception" >> fail exn
  in

  let ps = string_of_int port in
  yap ~tag ("-> start @ " ^ ps ^ " (use `openssl s_client -connect host:" ^ ps ^ " -servername foo` (or -servername bar))")
  >>
  let rec loop () =
    let config = Tls.Config.server ~certificates:(`Multiple [barcert ; foocert]) () in
    lwt (t, addr) = Tls_lwt.Unix.accept ~trace:eprint_sexp config server_s in
    yap ~tag "-> connect"
    >>
    ( handle (Tls_lwt.Unix.epoch t) (Tls_lwt.of_t t) addr ; loop () )
  in
  loop ()


let echo_server port =
  Nocrypto_entropy_lwt.initialize () >>
  serve_ssl port @@ fun host (ic, oc) addr ->
    lines ic |> Lwt_stream.iter_s (fun line ->
      yap ("handler " ^ host) ("+ " ^ line) >> Lwt_io.write_line oc line)

let () =
  let port =
    try int_of_string Sys.argv.(1) with _ -> 4433
  in
  Lwt_main.run (echo_server port)
