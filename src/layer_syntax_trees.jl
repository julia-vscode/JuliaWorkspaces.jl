# JuliaSyntax's recursive-descent parser (and the recursive tree builders
# that walk its output: SyntaxNode construction and CSTConversion.build_cst)
# can StackOverflow on deeply nested, typically machine-generated, input
# (e.g. long `||` chains) at the default task stack size, even though
# CSTParser handles the same input fine. Run each recursive step on a Task
# with a large reserved stack to close that gap.
const PARSE_TASK_STACK_SIZE = 512 * 1024 * 1024

# Runs `f` on an enlarged-stack Task and reports success/failure instead of
# throwing, so callers can fall back to a safe minimal tree.
function _run_on_enlarged_stack(f)
    t = Task(PARSE_TASK_STACK_SIZE) do
        try
            (:ok, f())
        catch e
            (:error, e, catch_backtrace())
        end
    end
    schedule(t)
    try
        return fetch(t)
    catch e
        return (:error, e, catch_backtrace())
    end
end

# Never-throw fallback: a single :toplevel node wrapping one error leaf that
# spans the whole file, so downstream consumers (SyntaxNode / CSTConversion)
# still see a well-formed, fully-tiled tree instead of a query throw. Shallow
# by construction, so building/converting it never itself overflows.
function _error_fallback_green(content::AbstractString)
    n = sizeof(content)
    leaf = JuliaSyntax.GreenNode(JuliaSyntax.SyntaxHead(K"error", JuliaSyntax.EMPTY_FLAGS), n)
    return JuliaSyntax.GreenNode(JuliaSyntax.SyntaxHead(K"toplevel", JuliaSyntax.EMPTY_FLAGS), n, [leaf])
end

Salsa.@derived function derived_julia_green_tree(rt, uri)
    @debug "derived_julia_green_tree" uri=uri
    tf = derived_text_file_content(rt, uri)
    content = tf.content.content
    status = _run_on_enlarged_stack() do
        stream = JuliaSyntax.ParseStream(content; version=VERSION)
        JuliaSyntax.parse!(stream; rule=:all)
        green = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
        (green, stream.diagnostics)
    end
    if status[1] == :ok
        green, diagnostics = status[2]
        return green, diagnostics, content
    else
        @error "JuliaSyntax parse failed; using error-fallback tree" uri=uri exception=(status[2], status[3])
        green = _error_fallback_green(content)
        diag = JuliaSyntax.Diagnostic(1, max(1, sizeof(content)); error="parse failed: $(sprint(showerror, status[2]))")
        return green, [diag], content
    end
end

Salsa.@derived function derived_julia_parse_result(rt, uri)
    green, diagnostics, content = derived_julia_green_tree(rt, uri)
    status = _run_on_enlarged_stack() do
        SyntaxNode(JuliaSyntax.SourceFile(content), green)
    end
    if status[1] == :ok
        return status[2], diagnostics
    else
        @error "SyntaxNode construction failed; using error-fallback tree" uri=uri exception=(status[2], status[3])
        tree = SyntaxNode(JuliaSyntax.SourceFile(content), _error_fallback_green(content))
        diag = JuliaSyntax.Diagnostic(1, max(1, sizeof(content)); error="SyntaxNode construction failed: $(sprint(showerror, status[2]))")
        return tree, vcat(diagnostics, [diag])
    end
end

Salsa.@derived function derived_julia_syntax_tree(rt, uri)
    return derived_julia_parse_result(rt, uri)[1]
end

@static if isdefined(JuliaSyntax, :byte_range)
    _range(x) = JuliaSyntax.byte_range(x)
else
    _range(x) = range(x)
end

Salsa.@derived function derived_julia_syntax_diagnostics(rt, uri)
    parse_result = derived_julia_parse_result(rt, uri)

    diag_results = map(parse_result[2]) do i
        Diagnostic(
            _range(i),
            i.level,
            i.message,
            nothing,
            Symbol[],
            "JuliaSyntax.jl"
        )
    end

    return diag_results
end

# Backend escape hatch while the converter soaks; read once at load time.
const CST_BACKEND = Ref(get(ENV, "JW_CST_BACKEND", "juliasyntax"))

Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    @debug "derived_julia_legacy_syntax_tree" uri=uri
    if CST_BACKEND[] == "cstparser"
        tf = derived_text_file_content(rt, uri)
        content = tf.content.content
        status = _run_on_enlarged_stack() do
            CSTParser.parse(content, true)
        end
        if status[1] == :ok
            return status[2]
        else
            @error "CSTParser.parse failed; using error-fallback tree" uri=uri exception=(status[2], status[3])
            return CSTConversion.build_cst(_error_fallback_green(content), content)
        end
    end
    green, _, content = derived_julia_green_tree(rt, uri)
    status = _run_on_enlarged_stack() do
        CSTConversion.build_cst(green, content)
    end
    if status[1] == :ok
        return status[2]
    else
        @error "CSTConversion.build_cst failed; using error-fallback tree" uri=uri exception=(status[2], status[3])
        return CSTConversion.build_cst(_error_fallback_green(content), content)
    end
end

Salsa.@derived function derived_toml_parse_result(rt, uri)
    @debug "derived_toml_parse_result" uri=uri

    tf = derived_text_file_content(rt, uri)

    tf === nothing && return Dict{String,Any}(), Diagnostic[Diagnostic(1:1, :error, "File not found", nothing, Symbol[], "JuliaWorkspaces")]

    content = tf.content.content

    parse_result = Pkg.TOML.tryparse(content)

    if parse_result isa Pkg.TOML.ParserError
        return parse_result.table, Diagnostic[Diagnostic(parse_result.pos:parse_result.pos, :error, Base.TOML.format_error_message_for_err_type(parse_result), nothing, Symbol[], "TOML.jl")]
    else
        return parse_result, Diagnostic[]
    end
end

Salsa.@derived function derived_toml_syntax_tree(rt, uri)
    parse_result = derived_toml_parse_result(rt, uri)

    return parse_result[1]
end

Salsa.@derived function derived_toml_syntax_diagnostics(rt, uri)
    parse_result = derived_toml_parse_result(rt, uri)

    return parse_result[2]
end
