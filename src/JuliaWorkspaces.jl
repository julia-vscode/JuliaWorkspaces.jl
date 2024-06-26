module JuliaWorkspaces

import UUIDs, JuliaSyntax
using UUIDs: UUID
using JuliaSyntax: SyntaxNode
using Salsa

using AutoHashEquals

include("compat.jl")

import Pkg

include("URIs2/URIs2.jl")
import .URIs2
using .URIs2: filepath2uri, uri2filepath

using .URIs2: URI, @uri_str

export JuliaWorkspace,
    add_text_file,
    remove_file!,
    remove_all_children!,
    with_changes, TextFile, SourceText, TextChange,
    workspace_from_folders,
    add_folder_from_disc!,
    add_file_from_disc!,
    update_file_from_disc!,
    get_text_files,
    has_file,
    get_text_file,
    get_julia_syntax_tree,
    get_toml_syntax_tree,
    get_diagnostic,
    get_packages,
    get_projects,
    get_test_items,
    get_test_env,
    TextFile,
    SourceText

include("types.jl")
include("sourcetext.jl")
include("files.jl")
include("inputs.jl")
include("layer_files.jl")
include("layer_syntax_trees.jl")
include("layer_diagnostics.jl")
include("layer_projects.jl")
include("layer_testitems.jl")
include("fileio.jl")

end
