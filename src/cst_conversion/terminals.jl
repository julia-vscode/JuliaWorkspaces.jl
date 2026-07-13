# Mirrors CSTParser's literalmap/tokenkindtoheadmap, keyed by JuliaSyntax kind.
# K"String"/K"Char" are here for documentation only: the quote-content-quote
# triple JuliaSyntax emits for these is merged before terminal_expr ever sees
# the content leaf in isolation (see merge_quoted below).
const TERMINAL_HEADS = Dict{Kind,Symbol}(
    K"Identifier"      => :IDENTIFIER,
    K"MacroName"       => :IDENTIFIER,
    K"Integer"         => :INTEGER,
    K"Float"           => :FLOAT,
    K"Float32"         => :FLOAT,
    K"HexInt"          => :HEXINT,
    K"BinInt"          => :BININT,
    K"OctInt"          => :OCTINT,
    K"Char"            => :CHAR,
    K"String"          => :STRING,
)

token_text(leaf::Leaf, source::String) = source[leaf.pos:prevind(source, leaf.pos + leaf.span)]

# Oracle-pinned: keyword- and punctuation-headed EXPRs carry the raw token
# text as val (CSTParser's tokenkindtoheadmap path always calls val(ps.t,ps)),
# not nothing.
function terminal_expr(leaf::Leaf, source::String)
    k = leaf.kind
    if k == K"Identifier" && token_text(leaf, source) == "end"
        # "end" is Identifier-kinded both inside index/range context
        # (`a[end]`, wants CSTParser's END literal) and as a dot-getfield
        # field name (`a.end`, wants plain IDENTIFIER) — real block-closing
        # `end` is its own keyword kind either way. Default to END here;
        # the getfield/quotenode forms demote it back to IDENTIFIER.
        return EXPR(:END, leaf.fullspan, leaf.span, "end")
    elseif k == K"Identifier" && token_text(leaf, source) == "begin"
        # Same story as `end` above (`a[begin]` vs `a.begin`).
        return EXPR(:BEGIN, leaf.fullspan, leaf.span, "begin")
    elseif k == K"Bool"
        # true/false share one Kind; CSTParser distinguishes by literal text.
        txt = token_text(leaf, source)
        return EXPR(txt == "true" ? :TRUE : :FALSE, leaf.fullspan, leaf.span, txt)
    elseif k == K"Placeholder"
        # Absent-catch-var marker (zero-width). 0.4 spelled this leaf's kind
        # "false"; CSTParser still expects a FALSE literal there.
        return EXPR(:FALSE, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif k == K"StringMacroName" || k == K"CmdMacroName"
        # `m"str"`/`c\`cmd\`` desugar to calling `@m_str`/`@c_cmd`; the
        # green leaf only carries the bare name, oracle wants the mangled one.
        suffix = k == K"StringMacroName" ? "_str" : "_cmd"
        return EXPR(:IDENTIFIER, leaf.fullspan, leaf.span, "@" * token_text(leaf, source) * suffix)
    elseif k == K"Identifier" && Base.isoperator(Symbol(token_text(leaf, source)))
        # 1.x reclassifies an operator token used in "value" position (call
        # target, bare `(+)`, etc.) as plain Identifier — the AST doesn't
        # distinguish an operator symbol from any other Symbol there. Text
        # is the only remaining way to tell; oracle still wants OPERATOR.
        return EXPR(:OPERATOR, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif JuliaSyntax.is_operator(k)
        return EXPR(:OPERATOR, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif JuliaSyntax.is_keyword(k)
        return EXPR(Symbol(uppercase(string(k))), leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif haskey(TERMINAL_HEADS, k)
        return EXPR(TERMINAL_HEADS[k], leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif JuliaSyntax.is_error(k)
        # Zero-width diagnostic marker for a missing/unexpected token in
        # broken code; mirrors CSTParser's errortoken so recovery keeps spans
        # consistent instead of crashing the whole corpus file.
        return EXPR(:errortoken, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif leaf.span == 0
        # Zero-width marker kind with no punctuation mapping (e.g.
        # K"TOMBSTONE", an internal deleted-token placeholder that
        # shouldn't normally reach the built tree but might under
        # recovery) — no real punctuation has zero width, so treat this
        # like any other error marker instead of a KeyError.
        return EXPR(:errortoken, leaf.fullspan, leaf.span, token_text(leaf, source))
    else
        return EXPR(punctuation_head(k), leaf.fullspan, leaf.span, token_text(leaf, source))
    end
end

# Mirrors tokenkindtoheadmap's punctuation entries. Unmapped kinds map to
# :errortoken instead of a KeyError: with full oracle parity on valid code
# the only unmapped leaves left are recovery shapes (e.g. a bare quote leaf
# under an error node for `x = "`), and a wrong head there still shows up
# loudly in oracle diffs while a throw would kill the whole file.
const PUNCTUATION_HEADS = Dict{Kind,Symbol}(
    K"(" => :LPAREN,   K")" => :RPAREN,
    K"[" => :LSQUARE,  K"]" => :RSQUARE,
    K"{" => :LBRACE,   K"}" => :RBRACE,
    K"," => :COMMA,
    K"@" => :ATSIGN,   K"." => :DOT,
    K";" => :SEMICOLON,
)
punctuation_head(k::Kind) = get(PUNCTUATION_HEADS, k, :errortoken)

# JuliaSyntax splits quoted literals into open-quote/content/close-quote
# leaves; CSTParser sees them as one STRING or CHAR token. Merges a run of
# leaves starting at a quote leaf into a single EXPR, returning the next
# unconsumed index. Interpolation and triple-quoted/cmd literals are out of
# scope here (Task 4 territory).
function merge_quoted(leaves::Vector{Leaf}, i::Int, source::String, hi::Int)
    open = leaves[i]
    n = min(hi, length(leaves))
    j = i + 1
    content = nothing
    while j <= n && leaves[j].kind != open.kind
        content = leaves[j]
        j += 1
    end
    # Unterminated literal at EOF (broken input): no closing quote leaf
    # exists — fall back to the last consumed leaf instead of indexing
    # past the end; there's nothing left to consume either way.
    closed = j <= n
    close = closed ? leaves[j] : leaves[n]
    next_i = closed ? j + 1 : n + 1
    fullspan = close.pos - open.pos + close.fullspan
    span = close.pos - open.pos + close.span
    if open.kind == K"\""
        # CSTParser stores unescaped content (parse_string_or_cmd runs
        # _rm_escaped_newlines + _unescape_string_expr); reuse its routines.
        expr = EXPR(:STRING, fullspan, span,
                    content === nothing ? "" : token_text(content, source))
        CSTParser._rm_escaped_newlines(expr)
        CSTParser._unescape_string_expr(expr)
        return expr, next_i
    else # K"'"
        val = source[open.pos:prevind(source, close.pos + close.span)]
        return EXPR(:CHAR, fullspan, span, val), next_i
    end
end

# --- interpolated/triple-quoted strings and cmd literals --------------------
#
# JuliaSyntax's green tree already decomposes an interpolated K"string" node
# into real children (content leaves, a `$` leaf, the interpolated
# subexpression), so merge_quoted's simple single-content-leaf assumption
# breaks down for: (a) real interpolation, (b) escaped-newline continuations
# that split one logical chunk across multiple String leaves joined by a
# Whitespace trivia leaf (merge_quoted only kept the LAST such leaf), and (c)
# triple-quote dedent. All three are handled uniformly here by re-slicing raw
# source between quote/interpolation boundaries instead of trusting any
# single leaf's own .val — CSTParser's own chunk spans fall out of that
# re-slice plus its own escape/dedent post-processing (ported below since
# it's a local closure in CSTParser, not reusable directly).
#
# K"cmdstring" is a genuine parser divergence at the LEXER level: JuliaSyntax
# never splits cmd-literal interpolation into green children at all (real
# Julia defers `$`-splitting in backtick literals to the @cmd macro at
# expansion time) — a plain CmdString leaf's raw text can contain a literal
# unescaped `$` with no corresponding child node. CSTParser's own tokenizer
# eagerly splits it instead, so matching its output requires a manual
# re-scan of the leaf's raw text (bare-identifier interpolation only;
# `$(...)` inside a cmd literal is not attempted).

# Longest-common-prefix dedent, ported from CSTParser's parse_string_or_cmd
# (the `adjust_lcp` closure) — operates on plain chunk text instead of EXPRs
# since our chunks come from re-sliced source, threading the shared `lcp`
# state via a Ref instead of a closure variable.
function adjust_lcp!(lcp::Base.RefValue{Union{Nothing,String}}, str::String, islast::Bool)
    (isempty(str) || (lcp[] !== nothing && isempty(lcp[]))) && return
    if islast && str[end] == '\n'
        lcp[] = ""
        return
    end
    idxstart, idxend = 2, 1
    while nextind(str, idxend) - 1 < sizeof(str) && (lcp[] === nothing || !isempty(lcp[]))
        idxend = CSTParser.skip_to_nl(str, idxend)
        idxstart = nextind(str, idxend)
        while nextind(str, idxend) - 1 < sizeof(str)
            c = str[nextind(str, idxend)]
            if c == ' ' || c == '\t'
                idxend += 1
            elseif c == '\n'
                idxend += 1
                idxstart = idxend + 1
            else
                prefix = str[idxstart:idxend]
                lcp[] = lcp[] === nothing ? prefix : CSTParser.longest_common_prefix(lcp[], prefix)
                break
            end
        end
    end
    if idxstart != nextind(str, idxend)
        prefix = str[idxstart:idxend]
        lcp[] = lcp[] === nothing ? prefix : CSTParser.longest_common_prefix(lcp[], prefix)
    end
end

rm_escaped_newlines_str(s::String) = (e = EXPR(:STRING, 0, 0, s); CSTParser._rm_escaped_newlines(e); e.val)
unescape_str(s::String) = (e = EXPR(:STRING, 0, 0, s); CSTParser._unescape_string_expr(e); e.val)

# Plain byte-range slice, unlike `source[a:b]` which additionally demands `b`
# itself start a valid character (Julia's String indexing is codepoint-
# aware) — our chunk boundaries are byte positions immediately before the
# NEXT real token, which is only guaranteed to be a valid character-END
# (not necessarily -START) when the preceding content ends in a multi-byte
# char (e.g. a docstring containing non-ASCII text).
byteslice(s::String, a::Int, b::Int) = a <= b ? String(@view codeunits(s)[a:b]) : ""

# var"..." nonstandard identifier: JuliaSyntax splits it into var/quote/
# content/quote leaves; CSTParser sees a NONSTDIDENTIFIER wrapping
# IDENTIFIER("var") and a STRING of the (raw) quoted content.
function merge_var(leaves::Vector{Leaf}, i::Int, source::String, hi::Int)
    var_leaf = leaves[i]
    var_id = EXPR(:IDENTIFIER, var_leaf.fullspan, var_leaf.span, "var")
    open = leaves[i+1]
    n = min(hi, length(leaves))
    j = i + 2
    while j <= n && leaves[j].kind != open.kind
        j += 1
    end
    # Unterminated var"..." at EOF (broken input): no closing quote leaf —
    # fall back to the last consumed leaf instead of indexing past it.
    closed = j <= n
    close = closed ? leaves[j] : leaves[n]
    next_i = closed ? j + 1 : n + 1
    str = EXPR(:STRING, close.pos + close.fullspan - open.pos,
               close.pos + close.span - open.pos,
               byteslice(source, open.pos + open.span, close.pos - 1))
    ex = EXPR(:NONSTDIDENTIFIER, EXPR[var_id, str], nothing,
              close.pos + close.fullspan - var_leaf.pos,
              close.pos + close.span - var_leaf.pos)
    return ex, next_i
end

DOLLAR_TRIVIA() = EXPR[EXPR(:OPERATOR, 1, 1, "\$")]

# A BARE string literal as the whole `$(...)` subexpression keeps its
# :string wrapper in CSTParser (parse_string_or_cmd explicitly re-wraps,
# since the usual single-chunk unwrap "is not supposed to happen in
# interpolations") — our single-chunk collapse must be undone here. Wrapper
# is oracle-pinned: trivia is EXPR[] (empty, not nothing), spans copied.
function rewrap_string_interp(ex::EXPR)
    if ex.head === :STRING || ex.head === :TRIPLESTRING
        return EXPR(:string, EXPR[ex], EXPR[], ex.fullspan, ex.span)
    end
    return ex
end

# Manual re-scan of a cmdstring leaf's raw text for interpolation (`$foo` or
# `$(...)`) — JuliaSyntax gives no green children to walk here (see
# module-level note above). `\`-escapes are skipped over without inspection,
# matching CSTParser's own scan. `s` is the absolute source position of
# `text[1]`. `$(...)` bracket matching is naive (paren-depth only, no
# awareness of nested strings/comments containing parens) but sufficient for
# real command-construction code.
function split_cmd_dollar(text::String, s::Int)
    out = Any[]
    len = ncodeunits(text)
    i = 1
    lastpos = 1
    while i <= len
        c = text[i]
        if c == '\\'
            i = i < len ? nextind(text, i, 2) : nextind(text, i)
        elseif c == '$' && nextind(text, i) <= len && text[nextind(text, i)] == '('
            depth = 1
            j = nextind(text, i, 2)
            open_j = j
            while j <= len && depth > 0
                text[j] == '(' && (depth += 1)
                text[j] == ')' && (depth -= 1)
                depth > 0 && (j = nextind(text, j))
            end
            # Only commit the pending literal run once a real split point is
            # confirmed — an unterminated `$(` (depth never hits 0) leaves
            # the whole rest as literal text instead.
            inner = depth == 0 ? text[open_j:prevind(text, j)] : ""
            iex = depth == 0 ? build_cst(inner) : nothing
            if depth == 0 && !isempty(iex.args)
                push!(out, (:lit, s + lastpos - 1, s + i - 2))
                leading, real = if iex.args[1].head === :NOTHING && length(iex.args) > 1
                    iex.args[1].fullspan, iex.args[2]
                else
                    0, iex.args[1]
                end
                trailing = real.fullspan - real.span
                real.fullspan -= trailing
                lparen = EXPR(:LPAREN, 1 + leading, 1, nothing)
                rparen = EXPR(:RPAREN, 1 + trailing, 1, nothing)
                trivia = EXPR[EXPR(:OPERATOR, 1, 1, "\$"), lparen, rparen]
                push!(out, (:interp, rewrap_string_interp(real), trivia))
                lastpos = nextind(text, j)
                i = lastpos
            else
                i = nextind(text, i)
            end
        elseif c == '$'
            j = nextind(text, i)
            idstart = j
            if j <= len && Base.is_id_start_char(text[j])
                j = nextind(text, j)
                while j <= len && Base.is_id_char(text[j])
                    j = nextind(text, j)
                end
            end
            if j > idstart
                # Only commit the pending literal run once a real split point
                # is confirmed — pushing it eagerly (before knowing whether
                # `$` is followed by an identifier) would re-push/duplicate
                # the same run on every subsequent `$(...)` that turns out
                # not to be a bare-identifier interpolation.
                push!(out, (:lit, s + lastpos - 1, s + i - 2))
                idtext = text[idstart:prevind(text, j)]
                clen = sizeof(idtext)
                push!(out, (:interp, EXPR(:IDENTIFIER, clen, clen, idtext), DOLLAR_TRIVIA()))
                lastpos = j
                i = j
            else
                i = nextind(text, i)
            end
        else
            i = nextind(text, i)
        end
    end
    push!(out, (:lit, s + lastpos - 1, s + len - 1))
    return out
end

# Walks a K"string"/K"cmdstring" green node's children, consuming the
# whole run via `cur` (quote/content leaves manually, interpolation
# subexpressions via ordinary recursive `assemble`), producing a flat list
# of (:lit, start_pos, end_pos) / (:interp, EXPR) pieces in source order.
# `start_pos > end_pos` marks an empty literal run at that position (still
# needed downstream to fold quote width onto an edge piece with no content).
function collect_quoted_pieces(node::GreenNode, cur::Cursor, iscmd::Bool)
    kids = [c for c in children(node) if !is_ws_trivia(kind(c))]
    open_leaf = cur.leaves[cur.i]
    cur.i += 1
    pieces = Any[]
    have_run = false
    run_start = 0
    close_leaf = open_leaf
    saw_close = false
    n = length(kids)
    j = 2
    while j <= n
        c = kids[j]
        k = kind(c)
        if k == K"String" || k == K"CmdString"
            leaf = cur.leaves[cur.i]
            have_run || (run_start = leaf.pos; have_run = true)
            cur.i += 1
            j += 1
        elseif JuliaSyntax.is_error(k)
            # Error kids inside a broken string (invalid escape, the
            # zero-width missing-close marker, a recovery-wrapped region)
            # are literal content bytes — extend the run instead of falling
            # into the close-quote branch below, which emits overlapping
            # chunks when visited more than once.
            nl = leaf_count(c)
            if nl > 0
                leaf = cur.leaves[cur.i]
                have_run || (run_start = leaf.pos; have_run = true)
                cur.i += nl
            end
            j += 1
        elseif k == K"$"
            leaf = cur.leaves[cur.i]
            chunk_start = have_run ? run_start : leaf.pos
            push!(pieces, (:lit, chunk_start, leaf.pos - 1))
            have_run = false
            dollar_ex = assemble(c, cur)
            j += 1
            trivia_here = EXPR[dollar_ex]
            if j > n
                # Broken input: `$` with nothing after it at all (e.g.
                # truncated right at EOF) — no sub-expression child exists
                # to descend into; keep the `$` itself reachable and stop.
                # `leaf` (the `$` itself) becomes the effective close, since
                # cur.i has already advanced past it and nothing follows.
                close_leaf = leaf
                saw_close = true
                push!(pieces, (:interp, EXPR(:errortoken, 0, 0, nothing), trivia_here))
                break
            end
            sub = kids[j]
            if kind(sub) == K"parens"
                pex = assemble(sub, cur)   # :brackets(args=[inner], trivia=[lparen,rparen])
                # CSTParser hand-builds these two (parse_string_or_cmd's own
                # `$(...)` path), unlike an ordinary parens grouping which
                # goes through the general tokenizer path — val is nothing
                # here, not the real "("/")" text.
                for t in pex.trivia
                    t.val = nothing
                end
                if isempty(pex.args)
                    # Broken interpolation (`$(` with no inner expression
                    # before EOF/recovery) — keep the whole brackets node
                    # instead of indexing into empty args.
                    push!(pieces, (:interp, pex, trivia_here))
                else
                    append!(trivia_here, pex.trivia)
                    push!(pieces, (:interp, rewrap_string_interp(pex.args[1]), trivia_here))
                end
            else
                push!(pieces, (:interp, assemble(sub, cur), trivia_here))
            end
            j += 1
        else
            close_leaf = cur.leaves[cur.i]
            saw_close = true
            chunk_start = have_run ? run_start : close_leaf.pos
            push!(pieces, (:lit, chunk_start, close_leaf.pos - 1))
            have_run = false
            cur.i += 1
            j += 1
        end
    end
    if !saw_close
        # Truncated literal at EOF: no closing-quote leaf exists. Synthesize
        # a zero-width close at the node's end so the edge-fold arithmetic
        # (and the node's own span) stays correct, and emit any pending run.
        last_leaf = cur.leaves[cur.i - 1]
        endpos = last_leaf.pos + last_leaf.fullspan
        close_leaf = Leaf(open_leaf.kind, endpos, 0, 0)
        push!(pieces, (:lit, have_run ? run_start : endpos, endpos - 1))
    end
    if iscmd
        @assert length(pieces) == 1 && pieces[1][1] == :lit
        _, s, e = pieces[1]
        pieces = s <= e ? split_cmd_dollar(byteslice(cur.src, s, e), s) : pieces
    end
    return pieces, open_leaf, close_leaf
end

# Builds the final EXPR for a K"string"/K"cmdstring" node from its pieces —
# folds quote width onto the edge pieces (same convention as merge_quoted's
# single-chunk case), applies triple-quote dedent + leading-newline-drop
# (istrip-gated) and escape unescaping (skipped for cmd literals, which
# CSTParser leaves raw beyond the manual `$`-scan above), then collapses to
# a bare STRING/TRIPLESTRING when there was no real interpolation.
function assemble_quoted(node::GreenNode, cur::Cursor, iscmd::Bool)
    source = cur.src
    pieces, open_leaf, close_leaf = collect_quoted_pieces(node, cur, iscmd)
    istrip = open_leaf.kind == K"\"\"\"" || open_leaf.kind == K"```"
    n = length(pieces)

    lit_idx = [i for i in 1:n if pieces[i][1] == :lit]
    raw = Dict{Int,String}()
    for i in lit_idx
        _, s, e = pieces[i]
        raw[i] = byteslice(source, s, e)
    end
    last_lit_raw = raw[lit_idx[end]]

    # Macro-wrapped strings (raw"", r"", b"", ...) carry RAW_STRING_FLAG on
    # the K"string" node itself — exactly CSTParser's `prefixed != false`
    # path, which skips escape processing entirely except for halving
    # backslash runs before a quote/chunk-end (unescape_prefixed). Same
    # istrip dedent order as CSTParser's: prefixed-unescape BEFORE lcp.
    israw = JuliaSyntax.has_flags(JuliaSyntax.head(node), JuliaSyntax.RAW_STRING_FLAG)
    texts = if iscmd
        copy(raw)
    elseif israw
        Dict(i => String(CSTParser.unescape_prefixed(t)) for (i, t) in raw)
    else
        Dict(i => rm_escaped_newlines_str(t) for (i, t) in raw)
    end
    if istrip
        lcp = Base.RefValue{Union{Nothing,String}}(nothing)
        for i in lit_idx
            adjust_lcp!(lcp, texts[i], i == lit_idx[end])
        end
        if lcp[] !== nothing && !isempty(lcp[])
            for i in lit_idx
                texts[i] = replace(texts[i], "\n" * lcp[] => "\n")
            end
        end
        first_i = lit_idx[1]
        if !startswith(last_lit_raw, "\\n") && startswith(texts[first_i], "\n")
            texts[first_i] = texts[first_i][2:end]
        end
    end
    if !iscmd && !israw
        for i in lit_idx
            texts[i] = unescape_str(texts[i])
        end
    end

    exprs = Vector{EXPR}(undef, n)
    for i in 1:n
        p = pieces[i]
        if p[1] == :interp
            exprs[i] = p[2]
        else
            _, s, e = p
            if i == 1 && i == n
                fullspan = close_leaf.pos + close_leaf.fullspan - open_leaf.pos
                span = close_leaf.pos + close_leaf.span - open_leaf.pos
            elseif i == 1
                endpos = s <= e ? e : s - 1
                fullspan = span = endpos - open_leaf.pos + 1
            elseif i == n
                fullspan = close_leaf.pos + close_leaf.fullspan - s
                span = close_leaf.pos + close_leaf.span - s
            else
                fullspan = span = e - s + 1
            end
            head = (n == 1 && istrip) ? :TRIPLESTRING : :STRING
            exprs[i] = EXPR(head, fullspan, span, texts[i])
        end
    end

    if n == 1
        cur.terminals[cur.i - 1] = exprs[1]
        return exprs[1]
    end

    args = EXPR[]
    trivia = EXPR[]
    for i in 1:n
        if pieces[i][1] == :interp
            append!(trivia, pieces[i][3])
            push!(args, exprs[i])
        elseif pieces[i][2] <= pieces[i][3]
            # chunk with real raw content stays an arg even if its val is
            # "" after triple-quote dedent / leading-newline drop.
            push!(args, exprs[i])
        elseif i == 1 || i == n
            push!(trivia, exprs[i])   # empty edge chunk: carries the folded quote width
        end
        # empty non-edge chunk: dropped entirely (CSTParser never emits it)
    end
    fullspan = close_leaf.pos + close_leaf.fullspan - open_leaf.pos
    span = close_leaf.pos + close_leaf.span - open_leaf.pos
    str = EXPR(:string, args, trivia, fullspan, span)
    # The trailing chunk owns the closing quote; register it at the close
    # leaf's slot so a later `;`-fold (`f("$x"; k=1)`) widens the chunk (and,
    # via its parent, the string) — keeping childsums balanced.
    cur.terminals[cur.i - 1] = exprs[n]
    return str
end
