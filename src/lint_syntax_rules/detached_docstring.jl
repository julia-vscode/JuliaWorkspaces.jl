# detached_docstring: a docstring the parser attaches to nothing.
#
# A comment or a blank line between a docstring and the expression it documents
# severs the binding, and the text is evaluated and discarded. Only strings
# opening on a signature line are reported: a bare-name header (`    Foo`, no
# parentheses) is not, so most `module` docstrings are out of scope.

# A docstring also binds in `begin`/`quote` and `struct` bodies, but those are
# `K"block"` like an `if` branch or a parenthesised `(a; b)`, and telling them
# apart needs the green tree. Neither accounts for a single finding across a
# 56k-file sweep, so this checks the two containers that do.
function _is_docable_container(node::SyntaxNode)
    kind(node) === K"toplevel" && return true
    kind(node) === K"block" || return false
    p = node.parent
    return p !== nothing && kind(p) === K"module"
end

# Matched against the first non-blank line alone. It is the only line that can be
# a signature, and it keeps a leading `\s*` out of the pattern: `\s*` overlaps
# `[ \t]{2,}` on space and tab, which makes PCRE backtrack quadratically over a
# long indent run and eventually throw.
const _NAME = raw"[@\w!]+(?:\.[@\w!]+)*"
const _SIGNATURE = Regex(
    raw"\A[ \t]{2,}(?:" *
        _NAME * raw"[({]" * "|" *                                    # f(x), Foo{T}
        raw"\((?=[^)\n]*::)[^)\n]*\)[ \t]*\(" * "|" *             # (m::T)(x)
        _NAME * raw"[ \t]*<:" * "|" *                              # Foo <: Bar
        raw"(?:mutable[ \t]+struct|struct|abstract[ \t]+type|primitive[ \t]+type)[ \t]+[A-Za-z_]" * "|" *
        raw"@[\w!]+" *                                               # @m x y
    ")")

function _signature_line(s::AbstractString)
    for line in eachsplit(s, '\n')
        isempty(strip(line)) || return line
    end
    return nothing
end

# `$` can make the text anything, so an interpolated string is never classified.
function _literal_value(node::SyntaxNode)
    io = IOBuffer()
    for c in children(node)
        kind(c) === K"String" && c.val isa AbstractString || return nothing
        print(io, c.val)
    end
    return String(take!(io))
end

function _looks_like_docstring(node::SyntaxNode)
    s = _literal_value(node)
    s === nothing && return false
    line = _signature_line(s)
    return line !== nothing && occursin(_SIGNATURE, line)
end

const _DETACHED_DOCSTRING_MESSAGE = "A docstring must be immediately followed by the expression it documents; this one is not, so its text is discarded."

function _check_detached_docstring(emit!, node, _ctx)
    _is_docable_container(node) || return nothing
    for c in children(node)
        kind(c) === K"string" && _looks_like_docstring(c) &&
            emit!(_node_range(c), _DETACHED_DOCSTRING_MESSAGE)
    end
    return nothing
end

const DETACHED_DOCSTRING_CHECK = SyntaxCheck(:detached_docstring, (K"toplevel", K"block"), _check_detached_docstring)
