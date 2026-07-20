# `textDocument/diagnostic` snapshot consistency (2026-07-18)

Follow-up to the LanguageServer crash fix `accf992` ("clamp out-of-bounds
diagnostic ranges instead of crashing the request"). That commit is
defense-in-depth — it stops a stale/racy range from crashing the request loop.
This doc captures the **protocol-correct** fix for the underlying staleness, left
as a deliberate follow-up.

## The crash (already fixed defensively)

`textDocument/diagnostic` (pull diagnostics), handler in
`LanguageServer/src/requests/textdocument.jl`:

```julia
function textDocument_diagnostic_request(params, server, conn)
    jw_diags = get_diagnostic(server.workspace, uri)          # read #1: diagnostics
    result_id = string(hash(jw_diags))
    ...
    lsp_diags = build_lsp_diagnostics(server, uri, jw_diags)  # read #2 inside: st = get_text_file(...).content
    return FullDocumentDiagnosticReport("full", result_id, lsp_diags)
end
```

`build_lsp_diagnostics` (`testitem_diagnostic_marking.jl`) fetches the document
text (`st`) **separately** from the diagnostics, then converts each diagnostic's
1-based half-open byte range against it via `Range(st, rng)` →
`get_position_from_offset`. The two workspace reads are not atomic, so if the
file is edited (shorter) between them, a diagnostic byte range can exceed the
current content length. Observed in the wild on `Revise.jl/src/packagedef.jl`:
`offset[110058] > sizeof(content)[110057]` — the diagnostics were from a
revision one byte longer than the text they were rendered against. Before the
fix this threw `LSPositionToOffsetException`, which propagated out of the request
handler and out of `run`, killing the server.

The clamp in `Range(st, rng)` now degrades such a range to the document end.
That prevents the crash but can briefly mis-position a diagnostic during the
race.

## Why we can't "match the request version"

LSP `DocumentDiagnosticParams` carries only a `TextDocumentIdentifier` — **no
document version**. So there is nothing in the request to match against; the
server always answers for "current" state. The staleness is entirely internal:
the diagnostics snapshot vs the text snapshot used to render them.

## Protocol-correct fix (the follow-up)

Two complementary pieces:

1. **Atomic snapshot for rendering (correctness).** Render diagnostic ranges
   against the *same* content revision the diagnostics were computed from,
   instead of a freshly-fetched `get_text_file`. Options, in rough order of
   preference:
   - Have `get_diagnostic` (or a sibling query) return the diagnostics **paired
     with the `SourceText`/content-hash** of the revision they were derived from,
     and pass that `SourceText` into `build_lsp_diagnostics` instead of
     re-reading. Ranges are then always in-bounds by construction; the clamp
     becomes a pure safety net.
   - Failing that, snapshot the workspace once at the top of the request and read
     both text and diagnostics from that snapshot (requires a
     consistent-read/snapshot handle on the JuliaWorkspace runtime).

2. **Staleness signalling (protocol).** When the document has moved on since the
   diagnostics were computed (compare the paired content-hash against the current
   `get_text_file` hash), return
   `DiagnosticServerCancellationData(retriggerRequest = true)` so the client
   re-pulls, per the pull-diagnostics spec, rather than returning a
   possibly-mispositioned `FullDocumentDiagnosticReport`. This needs the
   cancellation-data response type wired into the diagnostic response union.

## Scope / cautions

- The same separate-text-read pattern is used for **test-item** diagnostics
  (`testitem_diagnostic_marking.jl`, several `Range(st, …)` / `Range(st,
  code_range)` call sites). Whatever snapshot mechanism is chosen should cover
  those too — the clamp already does defensively.
- `get_position_from_offset` itself must stay strict (it's exercised
  exhaustively by `test_bruteforce.jl` and used by `get_offset`); the resilience
  belongs at the `Range(st, rng)` boundary (done) and, for correctness, at the
  snapshot-pairing layer above.
- A regression test exists for the clamp: `test/requests/test_textdocument.jl`,
  "Range: an out-of-bounds byte range clamps to EOF instead of crashing". A
  follow-up should add a test that the paired-snapshot path never produces an
  out-of-bounds range in the first place (drive a didChange that shortens the
  file between the diagnostics computation and the pull).
