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

function with_changes(source::SourceText, changes::Vector{TextChange})
    # TODO Optimize for scenario with 0 changes

    new_content = source.content
    
    for change in changes
        if change.span===nothing
            new_content = change.new_text
        else
        # TODO Unclear whether it really helps that we use three SubString values here, but maybe it makes things more type stable somehow?
        a = SubString(new_content, 1, prevind(new_content, change.span.start))
        b = SubString(change.new_text, 1)
        c = SubString(new_content, nextind(new_content, change.span.stop), lastindex(new_content))
        new_content = string(a, b, c)
        end
    end

    return SourceText(new_content, source.language_id)
end
