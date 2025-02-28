type opam_files = string list [@@deriving to_yojson, ord]

type ty =
  [ `Opam of [ `Build | `Lint of [ `Doc | `Opam ] ] * Selection.t * opam_files
  | `Opam_fmt of Selection.t * Analyse_ocamlformat.source option
  | `Opam_monorepo of Opam_monorepo.config ]
[@@deriving to_yojson, ord]

type t = { label : string; variant : Variant.t; ty : ty } [@@deriving ord]

let opam ~label ~selection ~analysis op =
  let variant = selection.Selection.variant in
  let ty =
    match op with
    | (`Build | `Lint (`Doc | `Opam)) as x ->
        `Opam (x, selection, Analyse.Analysis.opam_files analysis)
    | `Lint `Fmt ->
        `Opam_fmt (selection, Analyse.Analysis.ocamlformat_source analysis)
  in
  { label; variant; ty }

(** [lint_specs ~analysis selections] returns a list of valid linting specs,
    which may contain combinations of:

    - [(lint-fmt)]
    - [(lint-doc)]
    - [(lint-opam)] *)
let lint_specs ~analysis selections =
  (* Filter only linux-x86_64 and sort by OCaml version ascending *)
  let sorted_linux_x86_64_selections =
    List.filter
      (fun x ->
        Variant.arch x.Selection.variant == `X86_64
        && Variant.os x.variant == `linux)
      selections
    |> List.sort (fun x y ->
           Ocaml_version.compare
             (Variant.ocaml_version x.Selection.variant)
             (Variant.ocaml_version y.variant))
  in
  let lint_doc = List.hd sorted_linux_x86_64_selections in
  let lint_fmt =
    (* Allow fallback if an ocamlformat selection doesn't exist,
       as [dune build @fmt] can also format dune files *)
    match Analyse.Analysis.ocamlformat_selection analysis with
    | None -> lint_doc
    | Some spec -> spec
  in
  let lint_opam =
    (* Take the first selection with an OCaml version >= 4.14.0,
       as this is the lower-bound of [opam-dune-lint] *)
    List.find_opt
      (fun x ->
        Ocaml_version.(
          compare (Variant.ocaml_version x.Selection.variant) Releases.v4_14_0)
        >= 0)
      sorted_linux_x86_64_selections
  in
  let optional_spec ~label ~selection ~lint_ty =
    Option.map
      (fun selection -> [ opam ~label ~selection ~analysis (`Lint lint_ty) ])
      selection
    |> Option.value ~default:[]
  in
  [
    opam ~label:Variant.fmt_label ~selection:lint_fmt ~analysis (`Lint `Fmt);
    opam ~label:Variant.doc_label ~selection:lint_doc ~analysis (`Lint `Doc);
  ]
  @ optional_spec ~label:Variant.opam_label ~selection:lint_opam ~lint_ty:`Opam

let opam_monorepo builds =
  let multi = List.compare_length_with builds 2 >= 0 in
  List.map
    (fun config ->
      let { Selection.variant; _ } = Opam_monorepo.selection_of_config config in
      let label =
        if multi then Opam_monorepo.label config else Variant.to_string variant
      in
      { label; variant; ty = `Opam_monorepo config })
    builds

let pp f t = Fmt.string f t.label
let label t = t.label

let pp_summary f = function
  | `Opam (`Build, _, _) -> Fmt.string f "Opam project build"
  | `Opam (`Lint `Doc, _, _) -> Fmt.string f "Opam project lint documentation"
  | `Opam (`Lint `Opam, _, _) -> Fmt.string f "Opam files lint"
  | `Opam_fmt (_, v) ->
      Fmt.pf f "ocamlformat version: %a"
        Fmt.(option ~none:(any "none") Analyse_ocamlformat.pp_source)
        v
  | `Opam_monorepo _ -> Fmt.string f "opam-monorepo build"
