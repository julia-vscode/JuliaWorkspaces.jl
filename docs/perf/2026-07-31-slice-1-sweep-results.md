# The 74-root diagnostic sweep — slice 1 merge evidence (2026-07-31)

Produced by `docs/perf/typesweep.jl` for the slice-1 merge decision, comparing
`sp/module-inventory-design` against `main` (`c5e4481`) over the whole julia-vscode
repo. Preserved here because the harness was committed but its results lived in a
git-ignored scratch directory — the same reason lsbench was committed.

The sweep answers three questions a diagnostic count alone cannot: whether the new
check produces any diagnostic `main` does not (the false-positive direction),
whether the completeness marker over-triggers (invisible to any count, since it
only ever *removes* diagnostics), and whether the feature is actually live.

**Read `docs/design/2026-07-31-module-inventory-and-resolution.md` §17a and §17b for
the known holes this sweep is structurally unable to see** — an unparseable
mid-edit buffer above all, since a sweep analyses fixed content.

### Totals

| | |
|---|---|
| roots swept | **74** (both arms) |
| diagnostics, branch | **3776** |
| diagnostics, `main` | **3777** |
| **① present on branch, absent on `main`** | **1 — BLOCKER** |
| present on `main`, absent on branch | 2 (both explained, see below) |
| **② roots where the param-types index is empty and the arity index is not** | **15** (all traced to a real `eval`) |
| **③ distinct call sites reaching a full store-vs-store comparison** | **7043** |
| distinct call sites the comparison *rejected* | **1** (the blocker) |

### ① The blocker — one new diagnostic, in `Revise`

```
scripts/packages-old/v1.5/Revise/src/pkgs.jl   16564:16596   information
  No method matching `find_from_hash(::Any, ::Any, ::Nothing)`.
```

This is the sole rejection the instrumented `_tree_types_match` recorded anywhere
in the repo, so the attribution is direct: it comes from `ece1ce1`'s type check,
not from the earlier macro-declared slice.

The code (`pkgs.jl`, the legacy `manifest_paths!`):

```julia
uuid = name = path = hash = id = nothing
for line in eachline(io)
    if (m = match(Base.re_section_capture, line)) != nothing
        ...
    elseif (m = match(Base.re_uuid_to_string, line)) != nothing
        ...
        elseif hash !== nothing
            path = find_from_hash(name, uuid, hash)      # <-- flagged
        ...
    elseif (m = match(Base.re_hash_to_string, line)) != nothing
        hash = Base.SHA1(m.captures[1])
    end
end
...
function find_from_hash(name::String, uuid::Base.UUID, hash::Base.SHA1)
```

Verified in-session:

- `refof(hash, meta)` at the call site is `Binding(hash::(Core.Nothing))`, whose
  `.val` is the `hash = nothing` of the multi-assignment. The later
  `hash = Base.SHA1(...)` is a *separate* binding, later in source order.
- `call_arg_types` therefore returns `[Core.Any, Core.Any, Core.Nothing]`, all three
  store-resolved, so guard (c) does not decline.
- The recorded parameter types are `[["String"], ["Base","UUID"], ["Base","SHA1"]]`;
  `_has_type_intersection(Nothing, SHA1)` is false, so the call is rejected.

**It is a false positive.** The call is guarded by `hash !== nothing`, so `hash` is
a `Base.SHA1` whenever it runs. The defect is on the **argument** side, not the
method-set side: StaticLint's local type inference is flow-insensitive and, for a
local rebound in sibling branches, `refof` picks the textually preceding
`= nothing` binding. Nothing in the four documented method-set holes covers it.

**The one mitigating fact, which does not remove the blocker.** `main`'s
*whole-closure* pass already emits this exact diagnostic — same file, same range
`16564:16596`, same severity, same message. Confirmed by running
`derived_static_lint_diagnostics_for_root(rt, Revise)` in the `main` arm. So the
branch is not inventing a new false-positive *class*; it is reproducing, in
per-file mode, a verdict `sig_match_any` already reaches on `main` in the other
mode. Per-file mode was previously silent here only because its partial-method-set
gate declined.

**What the human has to decide.** Three options, none of them mine to take:

1. Accept it — the diagnostic already exists on `main` in the whole-closure path,
   so per-file mode is converging on `main`, not diverging from it. Cost: one known
   false positive ships in the mode that is actually used, and the flow-insensitive
   argument-side class is unbounded (this repo has one instance; another repo may
   have many).
2. Tighten guard (c) to decline when an argument's type comes from a local binding
   that is rebound elsewhere in its scope — i.e. treat a multi-binding local as
   unresolved. FP-safe, costs true positives, and is a change to StaticLint's
   argument side rather than to this slice.
3. Fix the flow-insensitivity (make `refof` on a rebound local yield the union of
   its bindings' types). Correct, much larger, and touches the pre-existing
   whole-closure path too — which would also delete the `main`-side diagnostic.

Recommendation, offered only as input: option 2 is the smallest change that keeps
the "a false positive is the one outcome this feature must not produce" constraint
intact, and it is naturally slice-1.5 work (it is a guard-(c) refinement, and 1.5
is already instructed to revisit guard (c) for per-index `Any`).

### ② Marker-fired roots — 15 of 74, every one a real `eval`

Roots where `derived_method_param_types_index` is empty while
`derived_method_arities_index` is not, with the statement that emitted the marker:

| root | arity keys | marker rows | shape |
|---|---|---|---|
| ChainRules | 81 | 4 | `let … quote … end` + 3× `for T in (…) @eval <def>` |
| CommonMark | 468 | 1 | `eval(Meta.parse("public Node, …"))` |
| Compat | 60 | 1 | `for op = (:/, :rem, :mod, :lcm, :gcd) @eval ($op)(x::Period, y::Period) = …` |
| DataStructures | 295 | 1 | `for _Dict = [:Dict, :OrderedDict] … @eval …` |
| IJuliaCore | 26 | 1 | `for s = ("stdout","stderr","stdin") … @eval …` |
| JSON | 54 | 1 | `for kind = ("object","array") … @eval …` |
| JuliaDynamicAnalysisProcess | 902 | 4 | 2× `Core.eval(@__MODULE__(), …)`, `let names = … eval …`, `for kind … @eval …` |
| JuliaFormatter | 367 | 5 | 5× `for f = [:n_import!, …] @eval function ($f)(…)` |
| LoggingExtras | 31 | 1 | `for L = (…) @eval function propagate…` |
| Onda | 67 | 1 | `for f = (:getindex, :view) @eval begin …` |
| Runic | 205 | 1 | `let str = "public format_file, format_string"; eval(Meta.parse(str)) end` |
| TestItemControllers | 280 | 1 | `for kind = ("object","array") … @eval …` |
| TestItemServer | 1089 | 4 | same four shapes as JuliaDynamicAnalysisProcess (vendored copies) |
| Tokenize | 73 | 1 | `eval(Meta.parse(str))` |
| VSCodeDebugger | 580 | 1 | `for kind = ("object","array") … @eval …` |

**Verdict: the marker does not over-trigger.** 24 marker rows across 2714 files;
every one is a genuine load-time `eval`, and 17 of the 24 are the `for … @eval
<method definition>` shape the marker exists for. No root is disabled by a
marker-free statement, and no root is disabled by a definition the walker could
have recorded.

**One coarseness note (not a defect, worth knowing before 1.5 narrows anything).**
Seven of the 24 rows are `eval`s that cannot define a *method*:
`Core.eval(@__MODULE__(), :(global juliadir::String))` (×2 per vendored Revise copy),
`eval(Meta.parse("public …"))` in CommonMark/Runic/Tokenize, and the
`let names = … eval` re-export block in the two `Compiler.jl` copies. Those
statements go through the `_has_load_time_eval` branch, which is deliberately
target- and content-blind, so they disable the feature for five substantial roots
(CommonMark 468 arity keys, Runic 205, Tokenize 73, JuliaDynamicAnalysisProcess 902,
TestItemServer 1089) without any method ever being at risk. This is coverage loss
in the sweep-invisible direction, exactly as the ledger warns; the conservative
choice is correct as long as narrowing it is measured rather than assumed.

### ③ Distinct call sites reaching a full store-vs-store comparison

7043 repo-wide, 1 rejected. Per-root figures are in the `cmp` column of the table
below. The reason for each zero:

- **Every heavily-typed root with `cmp = 0` is a marker-fired root** — the feature
  is inert there because the param-types index is empty (see ② for which `eval`).
  That accounts for all 15, including CommonMark (539 diagnostics, 468 arity keys,
  0 comparisons) and TestItemServer (1089 arity keys, 0 comparisons).
- The remaining zeros are the repo's small test-fixture packages (`BasicPackage`,
  `Dep442A`, `PkgA`, `TestPackage1–4`, `MainEnv`, `PC_C`/`PC_D`, `SetupPackage`,
  `WorkspaceTestEnv`, …), which have 0–7 index keys and no cross-file call that
  both passes the arity gate and has store-resolved arguments, plus `Compiler`
  (0 items — it is a re-export shim) and `VSCodeErrorLoggers` (1 key, 2 arity keys).
  None of these is a heavily-typed root.
- The largest live roots: JuliaWorkspaces 3003, CSTParser 1412, JuliaSyntax 788,
  JuliaInterpreter 461, Revise 219.

Also visible in the table, and worth carrying into 1.5: the gap between `ptkeys`
and `arkeys` is the per-name withholding (modelled-macro names and unqualified
external-import targets). It is large on the roots that import from `Base` a lot —
DebugAdapter 87/216, LanguageServer 117/355, OrderedCollections 18/54.

### Per-root table

`new` = ① (branch \ main). `gone` = main \ branch. `ptkeys`/`arkeys` = key counts of
`derived_method_param_types_index` / `derived_method_arities_index`. `cmp` = ③.
`rej` = call sites the comparison rejected.

```
root                        new  gone  branch   main  ptkeys  arkeys    cmp   rej  marker
AutoHashEquals                0     0      10     10      11      13     41     0
BasicPackage                  0     0       0      0       3       3      0     0
BrokenEnvPackage              0     0       0      0       1       1      0     0
BustedPackage                 0     0       0      0       1       1      0     0
CSTParser                     0     0      23     23     332     338   1412     0
CancellationTokens            0     0       6      6      15      20     37     0
ChainRules                    0     0      50     50       0      81      0     0  FIRED
CodeTracking                  0     0      11     11      24      27     49     0
CommonMark                    0     0     539    539       0     468      0     0  FIRED
Compat                        0     0      23     23       0      60      0     0  FIRED
Compiler                      0     0       0      0       0       0      0     0
CoverageTools                 0     0      12     12      26      28     32     0
Crayons                       0     0       1      1      41      42     76     0
DataStructures                0     0     129    129       0     295      0     0  FIRED
DebugAdapter                  0     0      59     59      87     216     56     0
DelimitedFiles                0     0      18     18      15      17     31     0
Dep442A                       0     0       0      0       1       1      0     0
Dep442B                       0     0       1      1       3       3      1     0
DependentEnv                  0     0       0      0       1       1      0     0
ExceptionUnwrapping           0     0       4      4      15      16     14     0
ExcludeFile                   0     0       0      0       1       1      0     0
FilePathsBase                 0     0      29     29     109     115     75     0
Glob                          0     0      12     12      14      21      9     0
IJuliaCore                    0     0       9      9       0      26      0     0  FIRED
JSON                          0     0      15     15       0      54      0     0  FIRED
JSONRPC                       0     0      17     17      28      35     38     0
JuliaDynamicAnalysisProcess   0     0     719    719       0     902      0     0  FIRED
JuliaFormatter                0     1      57     58       0     367      0     0  FIRED
JuliaInterpreter              0     0      61     61     184     203    461     0
JuliaSyntax                   0     0      43     43     337     353    788     0
JuliaSyntaxCore               0     0       0      0       1       1      0     0
JuliaWorkspaces               0     1     290    291    1070    1175   3003     0
LanguageServer                0     0      66     66     117     355    128     0
LoggingExtras                 0     0      19     19       0      31      0     0  FIRED
LoweredCodeUtils              0     0      15     15      67      68    117     0
MacroTools                    0     0      84     84      86      94    115     0
MainEnv                       0     0       0      0       1       1      0     0
MainTestProjectEnv            0     0       0      0       1       1      0     0
NoManifestPackage             0     0       2      2       1       2      0     0
Onda                          0     0      16     16       0      67      0     0  FIRED
OrderedCollections            0     0      12     12      18      54     12     0
PC_A                          0     0       0      0       2       3      3     0
PC_B                          0     0       0      0       0       0      0     0
PC_C                          0     0       0      0       2       4      0     0
PC_D                          0     0       0      0       0       0      0     0
PC_E                          0     0       0      0       2       2      2     0
PTest                         0     0       1      1       1       1      0     0
Pkg442                        0     0       0      0       1       1      0     0
PkgA                          0     0       0      0       2       2      0     0
PkgB                          0     0       0      0       2       2      0     0
PkgChange                     0     0       0      0       0       0      0     0
PrecompileTools               0     0       0      0       9       9      6     0
Preferences                   0     0       1      1      12      16     28     0
Revise                        1     0      72     71     133     140    219     1
Runic                         0     0      25     25       0     205      0     0  FIRED
Salsa                         0     0      12     12      85      99     67     0
Scratch                       0     0       1      1      11      12     11     0
ScratchUsage                  0     0       1      1       1       1      0     0
SetupPackage                  0     0       0      0       2       2      0     0
TestEnv                       0     0     114    114       8       9    100     0
TestItemControllers           0     0      66     66       0     280      0     0  FIRED
TestItemDetection             0     0       0      0       3       3     18     0
TestItemServer                0     0     778    778       0    1089      0     0  FIRED
TestPackage1                  0     0       1      1       0       0      0     0
TestPackage2                  0     0       1      1       0       0      0     0
TestPackage3                  0     0       1      1       0       0      0     0
TestPackage4                  0     0       1      1       0       0      0     0
Tokenize                      0     0       2      2       0      73      0     0  FIRED
URIParser                     0     0      15     15      22      26     29     0
URIs                          0     0      10     10      51      53     65     0
UsesPreferences               0     0       0      0       7       7      0     0
VSCodeDebugger                0     0     311    311       0     580      0     0  FIRED
VSCodeErrorLoggers            0     0      11     11       1       2      0     0
WorkspaceTestEnv              0     0       0      0       1       1      0     0
```


## Post-widening re-run
## Post-item-3 sweep — 0 new diagnostics beyond the accepted one

Same harness (`docs/perf/typesweep.jl`), same fixed base arm
(`arm-main.tsv`, `main` = `c5e4481`, 74 roots, 0 analysis errors, stdlib-only
fallback env). Branch arm re-run on the item-3 tree: 74 roots, **3776**
diagnostics, 0 analysis errors — the same total as the pre-item-3 branch arm.

| | vs `main` | vs pre-item-3 branch |
|---|---|---|
| new on branch | 7 | 6 |
| gone on branch | 8 | 6 |

**Every one of the 6 "new"/"gone" pairs is the same diagnostic at a shifted byte
offset in `src/layer_inventory.jl`** — the file item 3 edits, which is itself
swept, so the ~1.2 kB the two new helpers add moves every range after them. The
messages pair up 1:1 (one "argument … not used", two "Indexing with indices
obtained from `length`", three "assigned but not used"), and the vs-pre-item-3
comparison shows nothing else at all.

**So the genuine new-diagnostic count is 1 — the accepted Revise false positive,
unchanged in file, range `16564:16596`, severity and message.** Nothing beyond it.
`gone` vs `main` is likewise the 2 previously explained `Base.@deprecate` wins plus
the same 6 shifted ranges.

Item 3 therefore added no false positive and, in this repo, no new true positive
either: 810 more recorded parameter slots changed no verdict. (Consistent with the
earlier finding that the whole repo produces exactly one rejection.)

One harness note for the next session: `TypeBudget.load_folder` sees **2684**
files today, not the 2714 recorded above; the file set is a plain deterministic
walk, so the earlier figure was stale. It cannot bias the gate — a file that is
gone can only remove diagnostics — and the vs-pre-item-3 comparison, which shares
the file set exactly, is clean.

