open Macroperf

type copts = {
  output_file: string;
  ignore_out: [`Stdout | `Stderr] list;
}

let write_res ?(strip=[]) ?file res =
  let res = List.fold_left (fun a s -> Result.strip s a) res strip in

  (* Write the result into stdout, or <file> if specified *)
  (match file with
   | None -> Sexplib.Sexp.output_hum stdout @@ Result.sexp_of_t res
   | Some fn ->
       try Sexplib.Sexp.save_hum fn @@ Result.sexp_of_t res
       with Sys_error _ -> ()
         (* Sexplib cannot create temporary file, aborting*)
  );

  (* Write the result in cache too if cache exists *)
  let rex = Re_pcre.regexp " " in
  let name = res.Result.src.Benchmark.name |> String.trim in
  let name = Re_pcre.substitute ~rex ~subst:(fun _ -> "_") name in
  try
    let res_file =
      Util.FS.(cache_dir / name / res.Result.context_id ^ ".result") in
    XDGBaseDir.mkdir_openfile
      (fun fn -> Sexplib.Sexp.save_hum fn @@ Result.sexp_of_t res) res_file
  with Not_found -> ()

let write_res_copts copts res = match copts with
  | {output_file=""; ignore_out } -> write_res ~strip:ignore_out res
  | {output_file; ignore_out } -> write_res ~strip:ignore_out ~file:output_file res

(* Generic function to create and run a benchmark *)
let make_bench_and_run copts cmd bench_out topics =
  (* Build the name of the benchmark from the command line, but
     replace " " by "_" *)
  let cmd = Util.FS.(let hd = List.hd cmd in
                     if Filename.is_relative hd
                     then Unix.getcwd () / hd else hd)
            :: (List.tl cmd) in
  let name = String.concat " " cmd in
  let name_uscore = String.concat "_" cmd in
  let bench =
    Benchmark.make
      ~name:name_uscore
      ~descr:("Benchmark of " ^ name)
      ~cmd
      ~speed:`Fast
      ~topics ()
  in

  (* Write benchmark to file if asked for *)
  (match bench_out with
  | None -> ()
  | Some benchfile ->
      Sexplib.Sexp.save_hum benchfile @@ Benchmark.sexp_of_t bench);

  (* Run the benchmark *)
  let res = Runner.run_exn bench in

  (* Write the result in the file specified by -o, or stdout and maybe
     in cache as well *)
  write_res_copts copts res

let perf copts cmd evts bench_out =
  (* Separate events from the event list given in PERF format *)
  let rex = Re_pcre.regexp "," in
  let evts = Re_pcre.split ~rex evts in
  let evts = List.map (fun e -> Topic.(Topic (e, Perf))) evts in
  make_bench_and_run copts cmd bench_out evts

let libperf copts cmd evts bench_out =
  let rex = Re_pcre.regexp "," in
  let evts = Re_pcre.split ~rex evts in
  let rex = Re_pcre.regexp "-" in
  let evts = List.map
      (fun s -> s
                |> String.lowercase
                |> String.capitalize
                |> Re_pcre.substitute ~rex ~subst:(fun _ -> "_")
                |> Sexplib.Std.sexp_of_string
                |> fun s -> Topic.(Topic (Perf.Attr.Kind.t_of_sexp s, Libperf))
      ) evts
  in
  make_bench_and_run copts cmd bench_out evts

let kind_of_file filename =
  let open Unix in
  try
    let st = Unix.stat filename in
    match st.st_kind with
    | S_REG -> `File
    | S_DIR -> `Directory
    | _     -> `Other_kind
  with Unix_error (ENOENT, _, _) -> `Noent

let is_benchmark_file filename =
  kind_of_file filename = `File &&
  Filename.check_suffix filename ".bench"

let run copts switch selectors =
  let share = Util.Opam.share ?switch () in

  (* If no selectors, $OPAMROOT/$SWITCH/share/* become the selectors *)
  let selectors = match selectors with
    | [] ->
        let names = Util.FS.ls share in
        let names = List.map (fun n -> Filename.concat share n) names in
        List.filter (fun n -> kind_of_file n = `Directory)
          names
    | selectors -> selectors
  in
  (* If selector is a file, run the benchmark in the file, if it is
     a directory, run all benchmarks in the directory *)
  let rec run_inner selector =
    let run_bench filename =
      let b = Util.File.sexp_of_file_exn filename Benchmark.t_of_sexp in
      let res = Runner.run_exn b in
      write_res_copts copts res
    in
    match kind_of_file selector with
    | `Noent ->
        (* Not found, but can be an OPAM package name... *)
        (match kind_of_file Filename.(concat share selector) with
         | `Noent | `File | `Other_kind ->
             Printf.eprintf "Warning: %s is not an OPAM package.\n" selector
         | `Directory -> run_inner Filename.(concat share selector))
    | `Other_kind ->
        Printf.eprintf "Warning: %s is not a file nor a directory.\n" selector
    | `Directory ->
        (* Get a list of .bench files in the directory and run them *)
        Util.FS.ls selector
        |> List.map (Filename.concat selector)
        |> List.filter is_benchmark_file
        |> List.iter run_bench
    | `File ->
        List.iter run_bench [selector]
  in
  List.iter run_inner selectors

let help copts man_format cmds topic = match topic with
  | None -> `Help (`Pager, None) (* help about the program. *)
  | Some topic ->
      let topics = "topics" :: "patterns" :: "environment" :: cmds in
      let conv, _ = Cmdliner.Arg.enum (List.rev_map (fun s -> (s, s)) topics) in
      match conv topic with
      | `Error e -> `Error (false, e)
      | `Ok t when t = "topics" -> List.iter print_endline topics; `Ok ()
      | `Ok t when List.mem t cmds -> `Help (man_format, Some t)
      | `Ok t ->
          let page = (topic, 7, "", "", ""), [`S topic; `P "Say something";] in
          `Ok (Cmdliner.Manpage.print man_format Format.std_formatter page)

let list switch =
  let share = Util.Opam.share ?switch () in
  Util.FS.ls share
  |> List.map (fun n -> Filename.concat share n)
  |> List.filter (fun n -> kind_of_file n = `Directory)
  |> List.iter
    (fun selector ->
       Util.FS.ls selector
       |> List.map (Filename.concat selector)
       |> List.filter is_benchmark_file
       |> List.iter (fun s -> Format.printf "%s@." s))

(* [selectors] are bench _names_ *)
let summarize copts evts normalize csv selectors =
  let evts = let rex = Re_pcre.regexp "," in Re_pcre.split ~rex evts in
  let evts = List.map Topic.of_string evts in

  let selectors = match selectors with
    | [] -> [Util.FS.cache_dir]
    | ss -> List.fold_left
              (fun a s -> try
                  if Sys.is_directory s
                  then s::a (* selector is a directory, looking for content *)
                  else a (* selector is a file, do nothing *)
                with Sys_error _ ->
                  (* Not a file nor a dir: benchmark name *)
                  (try
                     if Sys.is_directory Util.FS.(cache_dir / s) then
                       Util.FS.(cache_dir / s)::a
                     else a
                   with Sys_error _ -> a)
              )
              [] ss
  in
  let create_summary_file fn =
    (* Summary file not found, we need to create it *)
    let result = Util.File.sexp_of_file_exn fn
        Result.t_of_sexp in
    let summary = Summary.of_result result in
    Summary.sexp_of_t summary
    |> Sexplib.Sexp.save_hum
      (Filename.chop_extension fn ^ ".summary");
    summary
  in
  let rec add_summary_to_db acc fn =
    Util.FS.fold (fun acc fn ->
        if Filename.check_suffix fn ".result"
        then
          (* Import the data contained in the file if it is a result
             file *)
          let summary_fn = (Filename.chop_extension fn ^ ".summary") in
          let s =
            if Sys.file_exists summary_fn &&
               Unix.((stat summary_fn).st_mtime > (stat fn).st_mtime)
            then
              try
                Util.File.sexp_of_file_exn
                  (Filename.chop_extension fn ^ ".summary")
                  Summary.t_of_sexp
              with Sys_error _ -> create_summary_file fn
            else
              create_summary_file fn
          in

          (* Filter on user requested evts *)
          let s_data = match evts with
            | [] -> s.Summary.data
            | evts -> TMap.filter (fun t _ -> List.mem t evts) s.Summary.data in

          (* Add summary data to datastructure *)
          Summary.(DB.add_tmap s.name s.context_id s_data acc)
        else
          acc
      ) acc fn
  in
  (* Create the DB *)
  let data = List.fold_left add_summary_to_db DB.empty selectors in
  let data = DB.fold
      (fun bench context_id topic measure a ->
         DB2.add topic bench context_id measure a
      )
      data DB2.empty in
  let data =
    (match normalize with
        | None -> data
        | Some "" -> DB2.normalize data
        | Some context_id -> DB2.normalize ~context_id data)
  in
  if not csv then
    match copts.output_file with
    | "" -> Sexplib.Sexp.output_hum stdout @@ DB2.sexp_of_t Summary.Aggr.sexp_of_t data
    | fn -> Sexplib.Sexp.save_hum fn @@ DB2.sexp_of_t Summary.Aggr.sexp_of_t data
  else
    match copts.output_file with
    | "" -> DB2.to_csv stdout data
    | fn -> Util.File.with_oc_safe (fun oc -> DB2.to_csv oc data) fn

open Cmdliner

(* Help sections common to all commands *)

let copts_sect = "COMMON OPTIONS"
let help_secs = [
  `S copts_sect;
  `P "These options are common to all commands.";
  `S "MORE HELP";
  `P "Use `$(mname) $(i,COMMAND) --help' for help on a single command.";
  `S "BUGS"; `P "Report bugs at <http://github.com/OCamlPro/oparf-macro>.";]

let copts output_file ignore_out =
  { output_file;
    ignore_out=List.map
        (function
          | "stdout" -> `Stdout
          | "stderr" -> `Stderr
          | _ -> invalid_arg "copts"
        )
        ignore_out
  }

let copts_t =
  let docs = copts_sect in
  let output_file =
    let doc = "File to write the result to (default: stdout)." in
    Arg.(value & opt string "" & info ["o"; "output"] ~docv:"file" ~docs ~doc) in
  let ignore_out =
    let doc = "Discard program output (default: none)." in
    Arg.(value & opt (list string) [] & info ["discard"] ~docv:"<channel>" ~docs ~doc) in
  Term.(pure copts $ output_file $ ignore_out)

let help_cmd =
  let topic =
    let doc = "The topic to get help on. `topics' lists the topics." in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
  in
  let doc = "Display help about macroperf and macroperf commands." in
  let man =
    [`S "DESCRIPTION";
     `P "Prints help about macroperf commands and other subjects..."] @ help_secs
  in
  Term.(ret (pure help $ copts_t $ Term.man_format $ Term.choice_names $topic)),
  Term.info "help" ~doc ~man

let default_cmd =
  let doc = "Macrobenchmarking suite for OCaml." in
  let man = help_secs in
  Term.(ret (pure (fun _ -> `Help (`Pager, None)) $ copts_t)),
  Term.info "macrorun" ~version:"0.1" ~sdocs:copts_sect ~doc ~man

(* Common arguments to perf_cmd, libperf_cmd *)
let bench_out =
  let doc = "Export the generated bench to file." in
  Arg.(value & opt (some string) None & info ["export"] ~docv:"file" ~doc)
let cmd =
  let doc = "Any command you can specify in a shell." in
  Arg.(non_empty & pos_all string [] & info [] ~docv:"<command>" ~doc)
let evts =
  let doc = "Same as the -e argument of PERF-STAT(1)." in
  Arg.(value & opt string "cycles" & info ["e"; "event"] ~docv:"perf-events" ~doc)

let perf_cmd =
  let doc = "Macrobenchmark using PERF-STAT(1) (Linux only)." in
  let man = [
    `S "DESCRIPTION";
    `P "Wrapper to the PERF-STAT(1) command."] @ help_secs
  in
  Term.(pure perf $ copts_t $ cmd $ evts $ bench_out),
  Term.info "perf" ~doc ~sdocs:copts_sect ~man

let libperf_cmd =
  let doc = "Macrobenchmark using the ocaml-perf library." in
  let man = [
    `S "DESCRIPTION";
    `P "See <http://github.com/vbmithr/ocaml-perf>."] @ help_secs
  in
  Term.(pure libperf $ copts_t $ cmd $ evts $ bench_out),
  Term.info "libperf" ~doc ~sdocs:copts_sect ~man

let switch =
  let doc = "Use the provided OPAM switch instead of using OPAM's current one." in
  Arg.(value & opt (some string) None & info ["switch"] ~docv:"OPAM switch name" ~doc)

let run_cmd =
  let selector =
    let doc = "If the argument correspond to a filename, the benchmark \
               is executed from this file, otherwise \
               the argument is treated as an OPAM package. \
               If missing, all OPAM benchmarks installed in \
               the current switch are executed." in
    Arg.(value & pos_all string [] & info [] ~docv:"<file|package>" ~doc)
  in
  let doc = "Run macrobenchmarks from files." in
  let man = [
    `S "DESCRIPTION";
    `P "Run macrobenchmarks from files."] @ help_secs
  in
  Term.(pure run $ copts_t $ switch $ selector),
  Term.info "run" ~doc ~sdocs:copts_sect ~man

let list_cmd =
  let doc = "List installed OPAM benchmarks." in
  let man = [
    `S "DESCRIPTION";
    `P "List installed OPAM benchmarks in the current switch."] @ help_secs
  in
  Term.(pure list $ switch),
  Term.info "list" ~doc ~man

let summarize_cmd =
  let evts =
    let doc = "Select the topic to summarize. \
This command understand gc stats, perf events, times... (default: all topics)." in
    Arg.(value & opt string "" & info ["e"; "event"] ~docv:"evts" ~doc) in
  let normalize =
    let doc = "Normalize against the value of a context_id (compiler)." in
    Arg.(value & opt ~vopt:(Some "") (some string) None &
         info ["n"; "normalize"] ~docv:"context_id" ~doc) in
  let csv =
    let doc = "Output in CSV format." in
    Arg.(value & flag & info ["csv"] ~docv:"boolean" ~doc) in
  let selector =
    let doc = "If the argument correspond to a file, it is taken \
               as a .result file, otherwise the argument is treated as \
               a benchmark name. \
               If missing, all results of previously ran benchmarks are used." in
    Arg.(value & pos_all string [] & info [] ~docv:"<file|name>" ~doc)
  in
  let doc = "Produce a summary of the result of the desired benchmarks." in
  let man = [
    `S "DESCRIPTION";
    `P "Produce a summary of the result of the desired benchmarks."] @ help_secs
  in
  Term.(pure summarize $ copts_t $ evts $ normalize $ csv $ selector),
  Term.info "summarize" ~doc ~man

let cmds = [help_cmd; run_cmd; summarize_cmd;
            list_cmd; perf_cmd; libperf_cmd]

let () = match Term.eval_choice ~catch:false default_cmd cmds with
  | `Error _ -> exit 1 | _ -> exit 0
