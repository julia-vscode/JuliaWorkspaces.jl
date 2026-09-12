# The semantic pass: a `TomlNode` tree to `Dict{String,Any}`, applying the
# table rules (a header may not reopen a defined table, inline tables and
# arrays are frozen, dotted keys create tables...). Rules and value types
# follow Base's `Base.TOML` parser so the result is interchangeable with
# `TOML.parse`, plus the spec rules Base misses. Every diagnostic points at
# the offending key.

const TomlTable = Dict{String,Any}

mutable struct _TableBuilder
    root::TomlTable
    active::TomlTable
    defined::Base.IdSet{TomlTable}       # created by a `[header]` / `[[header]]`
    dotted::Base.IdSet{TomlTable}        # created by dotted keys in a section since closed
    pending::Base.IdSet{TomlTable}       # created by dotted keys in the open section
    inline::Base.IdSet{TomlTable}        # inline tables (frozen)
    static_arrays::Base.IdSet{Any}       # `[...]` arrays (frozen)
    diagnostics::Vector{TomlDiagnostic}
end

function _TableBuilder()
    root = TomlTable()
    return _TableBuilder(root, root, Base.IdSet{TomlTable}(), Base.IdSet{TomlTable}(),
                         Base.IdSet{TomlTable}(), Base.IdSet{TomlTable}(), Base.IdSet{Any}(),
                         TomlDiagnostic[])
end

function _key_error!(b::_TableBuilder, code::TomlErrorKind, node::TomlNode)
    r = byte_range(node)
    push!(b.diagnostics, TomlDiagnostic(code, Int(first(r)), Int(last(r))))
    return nothing
end

# The parts of a `toml_key`, or nothing when any part is an error.
function _key_parts(keynode::TomlNode)
    kind(keynode) == K"toml_key" || return nothing
    parts = String[]
    for c in children(keynode)
        v = c.val
        v isa String || return nothing
        push!(parts, v)
    end
    isempty(parts) && return nothing
    return parts
end

function _has_error(node::TomlNode)
    is_error(node) && return true
    is_leaf(node) && return false
    return any(_has_error, children(node))
end

function _close_section!(b::_TableBuilder)
    for t in b.pending
        push!(b.dotted, t)
    end
    empty!(b.pending)
    return
end

# One step down a header path (all but the last part).
function _descend_header!(b::_TableBuilder, d::TomlTable, part::String, keynode::TomlNode)
    v = get(d, part, nothing)
    if v === nothing
        t = TomlTable()
        d[part] = t
        return t
    elseif v isa TomlTable
        v in b.inline && return _key_error!(b, ErrAddKeyToInlineTable, keynode)
        return v
    elseif v isa Vector && !(v in b.static_arrays) && !isempty(v) && v[end] isa TomlTable
        return v[end]::TomlTable   # array of tables: the last element
    end
    return _key_error!(b, ErrKeyAlreadyHasValue, keynode)
end

function _open_section!(b::_TableBuilder, node::TomlNode)
    b.active = TomlTable()   # detached scratch table until the header is accepted
    cs = children(node)
    isempty(cs) && return
    keynode = cs[1]
    parts = _key_parts(keynode)
    parts === nothing && return
    d = b.root
    for i in 1:length(parts)-1
        d = _descend_header!(b, d, parts[i], keynode)
        d === nothing && return
    end
    last = parts[end]
    existing = get(d, last, nothing)
    if kind(node) == K"toml_table"
        if existing === nothing
            t = TomlTable()
            d[last] = t
        elseif existing isa TomlTable
            existing in b.inline && return _key_error!(b, ErrAddKeyToInlineTable, keynode)
            (existing in b.defined || existing in b.dotted) && return _key_error!(b, ErrDuplicatedKey, keynode)
            t = existing
        elseif existing isa Vector && !(existing in b.static_arrays)
            return _key_error!(b, ErrDuplicatedKey, keynode)
        else
            return _key_error!(b, ErrKeyAlreadyHasValue, keynode)
        end
    else
        if existing === nothing
            arr = Any[]
            d[last] = arr
        elseif existing isa Vector
            existing in b.static_arrays && return _key_error!(b, ErrAddArrayToStaticArray, keynode)
            arr = existing
        else
            return _key_error!(b, ErrArrayTreatedAsDictionary, keynode)
        end
        t = TomlTable()
        push!(arr, t)
    end
    push!(b.defined, t)
    b.active = t
    return
end

function _add_keyval!(b::_TableBuilder, d::TomlTable, kv::TomlNode)
    cs = children(kv)
    length(cs) == 2 || return
    keynode, valnode = cs
    parts = _key_parts(keynode)
    parts === nothing && return
    _has_error(valnode) && return
    for i in 1:length(parts)-1
        part = parts[i]
        v = get(d, part, nothing)
        if v === nothing
            t = TomlTable()
            d[part] = t
            push!(b.pending, t)
            d = t
        elseif v isa TomlTable
            v in b.inline && return _key_error!(b, ErrAddKeyToInlineTable, keynode)
            (v in b.defined || v in b.dotted) && return _key_error!(b, ErrDuplicatedKey, keynode)
            d = v
        else
            return _key_error!(b, ErrKeyAlreadyHasValue, keynode)
        end
    end
    last = parts[end]
    existing = get(d, last, nothing)
    if existing !== nothing
        if existing isa TomlTable
            existing in b.inline && return _key_error!(b, ErrAddKeyToInlineTable, keynode)
            kind(valnode) == K"toml_inline_table" && return _key_error!(b, ErrInlineTableRedefine, keynode)
            return _key_error!(b, ErrDuplicatedKey, keynode)
        end
        return _key_error!(b, ErrKeyAlreadyHasValue, keynode)
    end
    d[last] = _value(b, valnode)
    return
end

function _value(b::_TableBuilder, node::TomlNode)
    k = kind(node)
    if k == K"toml_array"
        return _array_value(b, node)
    elseif k == K"toml_inline_table"
        t = TomlTable()
        push!(b.inline, t)
        for kv in children(node)
            kind(kv) == K"toml_keyval" && _add_keyval!(b, t, kv)
        end
        return t
    end
    return node.val
end

# Base narrows homogeneous arrays of a few scalar types; everything else
# stays `Vector{Any}`.
function _array_value(b::_TableBuilder, node::TomlNode)
    items = Any[_value(b, c) for c in children(node)]
    T = isempty(items) ? Union{} : typeof(items[1])
    for x in items
        if typeof(x) !== T
            T = Any
            break
        end
    end
    arr = if T === String || T === Bool || T === Int64 || T === UInt64 || T === Float64
        collect(T, items)
    else
        items
    end
    push!(b.static_arrays, arr)
    return arr
end

"""
    build_table(root::TomlNode) -> (Dict{String,Any}, Vector{TomlDiagnostic})

The document's table and the semantic diagnostics (duplicate keys, frozen
inline tables and arrays, ...). Items whose syntax is broken are skipped,
so a partially parsed file still yields every intact entry.
"""
function build_table(root::TomlNode)
    b = _TableBuilder()
    for child in children(root)
        k = kind(child)
        if k == K"toml_keyval"
            _add_keyval!(b, b.active, child)
        elseif k == K"toml_table" || k == K"toml_array_table"
            _close_section!(b)
            _open_section!(b, child)
            for c in children(child)
                kind(c) == K"toml_keyval" && _add_keyval!(b, b.active, c)
            end
        end
    end
    _close_section!(b)
    return b.root, b.diagnostics
end
