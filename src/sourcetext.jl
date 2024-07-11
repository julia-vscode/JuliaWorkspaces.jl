function _compute_line_indices(text)
    line_indices = Int[1]

    ind = firstindex(text)
    while ind <= lastindex(text)
        c = text[ind]
        if c == '\n' || c == '\r'
            if c == '\r' && ind + 1 <= lastindex(text) && text[ind + 1] == '\n'
                ind += 1
            end
            push!(line_indices, ind + 1)
        end

        ind = nextind(text, ind)
    end
    return line_indices
end
