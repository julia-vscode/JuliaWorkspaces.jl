function Documents()
    return Documents(
        Dict{URI,SourceText}(),
        Set{URI}(),
        Set{URI}()
    )
end


function with_changes(documents::Documents, changes::Vector{AbstractDocumentChange})
    new_documents = Documents(documents._sourcetexts, documents._notebook_files, documents._text_files)

    for change in changes
        if change isa DocumentChangeAddTextFile
            change.uri in new_documents._text_files && error("Duplicate file")
            haskey(new_documents._sourcetexts, change.uri) && error("Duplicate file")

            push!(new_documents._text_files, change.uri)
            new_documents._sourcetexts[change.uri] = change.content
        else
            error("Unknown change type")
        end
    end

    return new_documents
end
