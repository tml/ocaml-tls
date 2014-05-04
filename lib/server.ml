open Core
open Flow
open Flow.Or_alert

open Nocrypto

(* server configuration *)
type server_config = {
  key_file         : string ;
  certificate_file : string
}

let default_server_config = {
  key_file         = "server.key" ;
  certificate_file = "server.pem"
}

let answer_client_finished (sp : security_parameters) (packets : Cstruct.t list) (fin : Cstruct.t) (raw : Cstruct.t)  =
  let computed = Crypto.finished sp.protocol_version sp.master_secret "client finished" packets in
  fail_neq computed fin Packet.HANDSHAKE_FAILURE >>= fun () ->
  let my_checksum = Crypto.finished sp.protocol_version sp.master_secret "server finished" (packets @ [raw]) in
  let fin = Writer.assemble_handshake (Finished my_checksum) in
  let params = { sp with client_verify_data = computed ;
                         server_verify_data = my_checksum }
  in
  print_security_parameters params;
  return (`Established, params, [`Record (Packet.HANDSHAKE, fin)], `Pass)

let answer_client_key_exchange (sp : security_parameters) (packets : Cstruct.t list) (kex : Cstruct.t) (raw : Cstruct.t) =
  ( match Ciphersuite.ciphersuite_kex sp.ciphersuite with

    | Ciphersuite.RSA ->
       let private_key = match sp.own_certificate with
          | `Cert_private (_, pk) -> pk
          | `Cert_none            -> assert false in
          (* ^^^ Rig ciphersuite selection never to end up here if we haven't
           * got a cert. *)

       (* due to bleichenbacher attach, we should use a random pms *)
       (* then we do not leak any decryption or padding errors! *)
       let other = Writer.assemble_protocol_version sp.protocol_version <> Rng.generate 46 in
       let validate_premastersecret k =
         (* Client implementations MUST always send the correct version number in
            PreMasterSecret.  If ClientHello.client_version is TLS 1.1 or higher,
            server implementations MUST check the version number as described in
            the note below.  If the version number is TLS 1.0 or earlier, server
            implementations SHOULD check the version number, but MAY have a
            configuration option to disable the check.  Note that if the check
            fails, the PreMasterSecret SHOULD be randomized as described below *)
         match Cstruct.len k == 48,
               Reader.parse_version k,
               sp.protocol_version
         with
         | true, Reader.Or_error.Ok c_ver, TLS_1_0 ->
            if c_ver <= TLS_1_2 then return k else return other
         | true, Reader.Or_error.Ok c_ver, v       ->
            (* here, we need to check c_ver with Client_hello.client_version,
               as described in RFC5246, 7.4.7.1! -- not with protocol_version! *)
            if c_ver = v then return k else return other
         | _, _, _                                 ->
            (* should we have a similar conditional here? *)
            return other
       in
       ( match Crypto.decryptRSA_unpadPKCS1 private_key kex with
         | None   -> validate_premastersecret other
         | Some k -> validate_premastersecret k )

    | Ciphersuite.DHE_RSA ->
      (* we assume explicit communication here, not a client certificate *)
      ( match sp.dh_state with
        | `Sent (group, secret) -> return @@ DH.shared group secret kex
        | _                     -> fail Packet.HANDSHAKE_FAILURE  )

    | _ -> fail Packet.HANDSHAKE_FAILURE )

  >>= fun premastersecret ->
  let client_ctx, server_ctx, params =
    initialise_crypto_ctx sp premastersecret in
  let ps = packets @ [raw] in
  return (`KeysExchanged (Some server_ctx, Some client_ctx, ps), params, [], `Pass)

let answer_client_hello_params_int sp ch raw =
  let cipher = sp.ciphersuite in
  fail_false (List.mem cipher ch.ciphersuites) Packet.HANDSHAKE_FAILURE >>= fun () ->
  (* now we can provide a certificate with any of the given hostnames *)
  (match sp.server_name with
   | None   -> ()
   | Some x -> Printf.printf "was asked for hostname %s\n" x);
  let params = { sp with
                   server_random = Rng.generate 32 ;
                   client_random = ch.random } in
  (* RFC 4366: server shall reply with an empty hostname extension *)
  let host = match sp.server_name with
    | None   -> []
    | Some _ -> [Hostname None]
  in
  let secren = SecureRenegotiation
                 (params.client_verify_data <> params.server_verify_data)
  in
  let server_hello : server_hello =
    { version      = sp.protocol_version ;
      random       = params.server_random ;
      sessionid    = None ;
      ciphersuites = cipher ;
      extensions   = secren :: host } in
  let bufs = [Writer.assemble_handshake (ServerHello server_hello)] in
  let kex = Ciphersuite.ciphersuite_kex cipher in

  ( match sp.own_certificate, Ciphersuite.needs_certificate kex with
    | (`Cert_private (cert, _), true) ->
        let record =
          Writer.assemble_handshake (Certificate [Certificate.cs_of_cert cert]) in
        return (bufs @ [record], params)
    | (_, false) -> return (bufs, params)
    | _          -> fail Packet.HANDSHAKE_FAILURE )
    (* ^^^ Rig ciphersuite selection never to end up with one than needs a cert
     * if we haven't got one. *)

  >>= fun (bufs', params') ->
  ( if Ciphersuite.needs_server_kex kex then
      match kex with
      | Ciphersuite.DHE_RSA ->

          (* XXX
           * Can move group selection up into default params, or pick a group of
           * different size in this spot. *)
          let group         = DH.Group.oakley_2 in (* rfc2409 1024-bit group *)
          let (secret, msg) = DH.gen_secret group in
          let dh_state      = `Sent (group, secret) in
          let written =
            let dh_param = Crypto.dh_params_pack group msg in
            Writer.assemble_dh_parameters dh_param in

          let sign data =
            Crypto.padPKCS1_and_signRSA
              ( match sp.own_certificate with
                | `Cert_private (_, pk) -> pk
                | `Cert_none            -> assert false ) (* <- XXX XXX *)
              data
          in

          let data = params'.client_random <> params'.server_random <> written in

          ( match sp.protocol_version with
            | TLS_1_0 | TLS_1_1 ->
                         ( match sign Hash.( MD5.digest data <> SHA1.digest data ) with
                           | Some sign -> return (Writer.assemble_digitally_signed sign)
                           | None -> fail Packet.HANDSHAKE_FAILURE )
            | TLS_1_2 ->
               (* if no signature_algorithms extension is sent by the client,
                  support for md5 and sha1 can be safely assumed! *)
               let supported =
                 Utils.map_find ch.extensions
                                ~f:function
                                | SignatureAlgorithms xs -> Some xs
                                | _ -> None
               in
               ( match supported with
                 | Some xs ->
                    (* filter by Packet.RSA, then intersect with hashes *)
                    let poss = List.filter (function
                                             | (_, Packet.RSA) -> true
                                             | _               -> false) xs
                    in
                    let client_hashes = List.map (function (h, _) -> h) poss in
                    let my_hashes = default_config.hashes in
                    let supported x = List.mem x client_hashes in
                    fail_false (List.exists supported my_hashes) Packet.HANDSHAKE_FAILURE >>= fun () ->
                    return (List.hd (List.filter supported my_hashes))
                 | None    -> return Ciphersuite.SHA ) >>= fun (hash) ->
               ( match Crypto.pkcs1_digest_info_to_cstruct hash data with
                 | Some x -> return x
                 | None   -> fail Packet.HANDSHAKE_FAILURE ) >>= fun (to_sign) ->

               ( match sign to_sign with
                 | Some sign -> return (Writer.assemble_digitally_signed_1_2 hash Packet.RSA sign)
                 | None -> fail Packet.HANDSHAKE_FAILURE ) ) >>= fun (signature) ->
          let kex = written <> signature in
          return ( bufs' @ [Writer.assemble_handshake (ServerKeyExchange kex)]
                 , { params' with dh_state } )

    else return (bufs', params') )

  >>= fun (bufs'', params'') ->
  (* server hello done! *)
  let hello_done = Writer.assemble_handshake ServerHelloDone in
  let packets = bufs'' @ [hello_done] in
  return (`Handshaking (raw :: packets),
          params'',
          List.map (fun e -> `Record (Packet.HANDSHAKE, e)) packets,
          `Pass)

let answer_client_hello_params sp ch raw =
  let expected = sp.client_verify_data in
  check_reneg expected ch.extensions >>= fun () ->
  let host = find_hostname ch in
  fail_false (sp.server_name = host) Packet.HANDSHAKE_FAILURE >>= fun () ->
  fail_false (ch.version >= sp.protocol_version) Packet.PROTOCOL_VERSION >>= fun () ->
  answer_client_hello_params_int sp ch raw

let answer_client_hello sp (ch : client_hello) raw =
  fail_false (List.mem Ciphersuite.TLS_EMPTY_RENEGOTIATION_INFO_SCSV ch.ciphersuites) Packet.NO_RENEGOTIATION >>= fun () ->
  let issuported = fun x -> List.mem x ch.ciphersuites in
  fail_false (List.exists issuported default_config.ciphers) Packet.HANDSHAKE_FAILURE >>= fun () ->
  let ciphersuite = List.hd (List.filter issuported default_config.ciphers) in
  let server_name = find_hostname ch in
  ( match supported_protocol_version ch.version with
      | None   -> fail Packet.PROTOCOL_VERSION
      | Some x -> return x ) >>= fun (protocol_version) ->
  let params = { sp with
                   ciphersuite ;
                   protocol_version ;
                   server_name }
  in
  answer_client_hello_params_int params ch raw

let handle_change_cipher_spec sp = function
  | `KeysExchanged (enc, dec, _) as is ->
     let ccs = change_cipher_spec in
     return (is, sp, None, [`Record ccs; `Change_enc enc], `Change_dec dec)
  | _ -> fail Packet.UNEXPECTED_MESSAGE

let handle_handshake sp is buf =
  match Reader.parse_handshake buf with
  | Reader.Or_error.Ok handshake ->
     Printf.printf "HANDSHAKE: %s" (Printer.handshake_to_string handshake);
     Cstruct.hexdump buf;
     ( match (is, handshake) with
       | `Initial, ClientHello ch ->
          answer_client_hello sp ch buf
       | `Handshaking bs, ClientKeyExchange kex ->
          answer_client_key_exchange sp bs kex buf
       | `KeysExchanged (_, _, bs), Finished fin ->
          answer_client_finished sp bs fin buf
       | `Established, ClientHello ch -> (* key renegotiation *)
          answer_client_hello_params sp ch buf
       | _, _-> fail Packet.HANDSHAKE_FAILURE ) >>= fun (sp, is, res, dec) ->
       return (sp, is, None, res, dec)
  | _                           ->
     fail Packet.UNEXPECTED_MESSAGE

let handle_record
: tls_internal_state -> security_parameters -> Packet.content_type -> Cstruct.t
  -> (tls_internal_state * security_parameters * Cstruct.t option * rec_resp list * dec_resp) or_error
= fun is sp ct buf ->
  Printf.printf "HANDLE_RECORD (in state %s) %s\n"
                (state_to_string is)
                (Packet.content_type_to_string ct);
  match ct with
  | Packet.ALERT -> handle_alert sp buf
  | Packet.APPLICATION_DATA ->
     ( match is with
       | `Established -> return (is, sp, Some buf, [], `Pass)
       | _            -> fail Packet.UNEXPECTED_MESSAGE
     )
  | Packet.CHANGE_CIPHER_SPEC -> handle_change_cipher_spec sp is
  | Packet.HANDSHAKE -> handle_handshake sp is buf

let handle_tls = handle_tls_int handle_record

let new_connection ?cert () = new_state ?cert ()

