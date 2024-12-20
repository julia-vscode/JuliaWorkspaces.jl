var documenterSearchIndex = {"docs":
[{"location":"functions/#Functions","page":"Functions","title":"Functions","text":"","category":"section"},{"location":"functions/","page":"Functions","title":"Functions","text":"CurrentModule = JuliaWorkspaces","category":"page"},{"location":"functions/#Exported-functions","page":"Functions","title":"Exported functions","text":"","category":"section"},{"location":"functions/","page":"Functions","title":"Functions","text":"    add_file!\n    remove_file!\n    remove_all_children!\n    get_text_files\n    get_julia_files\n    has_file\n    get_text_file\n    get_julia_syntax_tree\n    get_toml_syntax_tree\n    get_diagnostic\n    get_packages\n    get_projects\n    get_test_items\n    get_test_env","category":"page"},{"location":"functions/#JuliaWorkspaces.add_file!","page":"Functions","title":"JuliaWorkspaces.add_file!","text":"add_file!(jw::JuliaWorkspace, file::TextFile)\n\nAdd a file to the workspace. If the file already exists, it will throw an error.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.remove_file!","page":"Functions","title":"JuliaWorkspaces.remove_file!","text":"remove_file!(jw::JuliaWorkspace, uri::URI)\n\nRemove a file from the workspace. If the file does not exist, it will throw an error.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.remove_all_children!","page":"Functions","title":"JuliaWorkspaces.remove_all_children!","text":"remove_all_children!(jw::JuliaWorkspace, uri::URI)\n\nRemove all children of a folder from the workspace.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_text_files","page":"Functions","title":"JuliaWorkspaces.get_text_files","text":"get_text_files(jw::JuliaWorkspace)\n\nGet all text files from the workspace.\n\nReturns\n\nA set of URIs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_julia_files","page":"Functions","title":"JuliaWorkspaces.get_julia_files","text":"get_julia_files(jw::JuliaWorkspace)\n\nGet all Julia files from the workspace.\n\nReturns\n\nA set of URIs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.has_file","page":"Functions","title":"JuliaWorkspaces.has_file","text":"has_file(jw, uri)\n\nCheck if a file exists in the workspace.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_text_file","page":"Functions","title":"JuliaWorkspaces.get_text_file","text":"get_text_file(jw::JuliaWorkspace, uri::URI)\n\nGet a text file from the workspace. If the file does not exist, it will throw an error.\n\nReturns\n\nA TextFile struct.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_julia_syntax_tree","page":"Functions","title":"JuliaWorkspaces.get_julia_syntax_tree","text":"get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)\n\nGet the syntax tree of a Julia file from the workspace.\n\nReturns\n\nThe tuple (tree, diagnostics), where tree is the syntax tree  and diagnostics is a vector of Diagnostic structs.   \n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_toml_syntax_tree","page":"Functions","title":"JuliaWorkspaces.get_toml_syntax_tree","text":"get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)\n\nGet the syntax tree of a TOML file from the workspace.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_diagnostic","page":"Functions","title":"JuliaWorkspaces.get_diagnostic","text":"get_diagnostic(jw::JuliaWorkspace, uri::URI)\n\nGet the diagnostics of a file from the workspace.\n\nReturns\n\nA vector of Diagnostic structs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_packages","page":"Functions","title":"JuliaWorkspaces.get_packages","text":"get_packages(jw::JuliaWorkspace)\n\nGet all packages from the workspace.\n\nReturns\n\nA set of URIs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_projects","page":"Functions","title":"JuliaWorkspaces.get_projects","text":"get_projects(jw::JuliaWorkspace)\n\nGet all projects from the workspace.\n\nReturns\n\nA set of URIs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_test_items","page":"Functions","title":"JuliaWorkspaces.get_test_items","text":"get_test_items(jw::JuliaWorkspace, uri::URI)\n\nGet the test items that belong to a given URI of a workspace.\n\nReturns\n\nan instance of the struct TestDetails\n\n\n\n\n\nget_test_items(jw::JuliaWorkspace)\n\nGet all test items of the workspace jw.\n\nReturns\n\nan instance of the struct TestDetails\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_test_env","page":"Functions","title":"JuliaWorkspaces.get_test_env","text":"get_test_env(jw::JuliaWorkspace, uri::URI)\n\nGet the test environment that belongs to the given uri of the workspace jw.\n\nReturns\n\nan instance of the struct JuliaTestEnv\n\n\n\n\n\n","category":"function"},{"location":"functions/#Private-functions","page":"Functions","title":"Private functions","text":"","category":"section"},{"location":"functions/","page":"Functions","title":"Functions","text":"get_files\nget_diagnostics\nupdate_file!","category":"page"},{"location":"functions/#JuliaWorkspaces.get_files","page":"Functions","title":"JuliaWorkspaces.get_files","text":"get_files(jw::JuliaWorkspace)\n\nGet all files from the workspace.\n\nReturns\n\nA set of URIs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.get_diagnostics","page":"Functions","title":"JuliaWorkspaces.get_diagnostics","text":"get_diagnostics(jw::JuliaWorkspace)\n\nGet all diagnostics from the workspace.\n\nReturns\n\nA vector of Diagnostic structs.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.update_file!","page":"Functions","title":"JuliaWorkspaces.update_file!","text":"update_file!(jw::JuliaWorkspace, file::TextFile)\n\nUpdate a file in the workspace. If the file does not exist, it will throw an error.\n\n\n\n\n\n","category":"function"},{"location":"functions/#URI-helper-functions-(submodule-URIs2)","page":"Functions","title":"URI helper functions (submodule URIs2)","text":"","category":"section"},{"location":"functions/","page":"Functions","title":"Functions","text":"URIs2.unescapeuri\nURIs2.escapeuri\nURIs2._bytes\nURIs2.escapepath","category":"page"},{"location":"functions/#JuliaWorkspaces.URIs2.unescapeuri","page":"Functions","title":"JuliaWorkspaces.URIs2.unescapeuri","text":"unescapeuri(str)\n\nPercent-decode a string according to the URI escaping rules.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.URIs2.escapeuri","page":"Functions","title":"JuliaWorkspaces.URIs2.escapeuri","text":"escapeuri(x)\n\nApply URI percent-encoding to escape special characters in x.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.URIs2._bytes","page":"Functions","title":"JuliaWorkspaces.URIs2._bytes","text":"_bytes(s::String)\n\nGet a Vector{UInt8}, a vector of bytes of a string.\n\n\n\n\n\n","category":"function"},{"location":"functions/#JuliaWorkspaces.URIs2.escapepath","page":"Functions","title":"JuliaWorkspaces.URIs2.escapepath","text":"escapepath(path)\n\nEscape the path portion of a URI, given the string path containing embedded / characters which separate the path segments.\n\n\n\n\n\n","category":"function"},{"location":"#JuliaWorkspaces.jl","page":"Home","title":"JuliaWorkspaces.jl","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Underlying engine for LanguageServer.jl","category":"page"},{"location":"#Design-ideas","page":"Home","title":"Design ideas","text":"","category":"section"},{"location":"#Planned-transitions","page":"Home","title":"Planned transitions","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"The first transition is that we want to adopt JuliaSyntax.jl for parsing and probably also its node types for representing code. Most of the LS at the moment is powered by CSTParser, which has its own parsing implementation and brings the main node type along that is used throughout the LS. At the same time, we have started to use JuliaSyntax in the LS (yes, at the moment everything gets parsed twice, once by CSTParser and once by JuliaSyntax) for some things, namely the test item detection stuff. The roadmap here is that I want to completely get rid of the CSTParser parser and exclusively use the JuliaSyntax parser. The medium term plan is that we will have one parsing pass that then generates trees for the old CSTParser node types and the JuliaSyntax node types. Once we are at that stage we’ll need to spend some more time thinking about node types and what exactly is the right fit for the LS.","category":"page"},{"location":"","page":"Home","title":"Home","text":"The second transition is towards a more functional/immutable/incremental computational model for most of the logic in the LS. At the moment the LS uses mutable data structures throughout, and keeping track of where state is mutated, and when is really, really tricky (well, at least for me). It also makes it completely hopeless that we might use multi threading at some point, for example. So this summer I started tackling that problem, and the strategy for that is that we use Salsa.jl as the core underlying design for the LS. There is an awesome JuliaCon video about that package from a couple of years ago for anyone curious. So that whole design is essentially inspired by the Rust language server. The outcome of that transition will be a much, much easier to reason about data model.","category":"page"},{"location":"#Goal","page":"Home","title":"Goal","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Very roughly, StaticLint/CSTParser/SymbolServer has all the code pre these transitions, and JuliaWorkspaces has the code that is in this new world of the two transitions I mentioned above. So the division is by generation of when stuff was added to the LS, not by functionality. My expectation is that once the transition is finished, StaticLint and SymbolServer will be no more as individual packages but their code will have been incorporated into JuliaWorkspaces. The final design I have in mind is that the LanguageServer.jl package really only has the code that implements the LSP wire protocol, but not much functionality in it, and all the functionality lives in JuliaWorkspaces. The idea being that we can then create for example CI tools that use the functionality in JuliaWorkspaces directly (like GitHub - julia-actions/julia-lint), or command line apps etc.","category":"page"},{"location":"types/#Types","page":"Types","title":"Types","text":"","category":"section"},{"location":"types/","page":"Types","title":"Types","text":"CurrentModule = JuliaWorkspaces","category":"page"},{"location":"types/#Exported-types","page":"Types","title":"Exported types","text":"","category":"section"},{"location":"types/","page":"Types","title":"Types","text":"TextFile\nSourceText","category":"page"},{"location":"types/#JuliaWorkspaces.TextFile","page":"Types","title":"JuliaWorkspaces.TextFile","text":"struct TextFile\n\nA text file, consisting of its URI and content.\n\nuri::URI: The URI of the file.\ncontent::SourceText: The content of the file as SourceText.\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.SourceText","page":"Types","title":"JuliaWorkspaces.SourceText","text":"struct SourceText\n\nA source text, consisting of its content, line indices, and language ID.\n\ncontent::String\nline_indices::Vector{Int}\nlanguage_id::String\n\n\n\n\n\n","category":"type"},{"location":"types/#Private-types","page":"Types","title":"Private types","text":"","category":"section"},{"location":"types/","page":"Types","title":"Types","text":"Diagnostic\nJuliaPackage\nJuliaTestEnv\nJuliaProject\nJuliaProjectEntryDevedPackage\nJuliaProjectEntryRegularPackage\nJuliaProjectEntryStdlibPackage\nJuliaWorkspace\nNotebookFile\nTestSetupDetail\nTestDetails\nTestItemDetail\nTestErrorDetail\nURI","category":"page"},{"location":"types/#JuliaWorkspaces.Diagnostic","page":"Types","title":"JuliaWorkspaces.Diagnostic","text":"struct Diagnostic\n\nA diagnostic struct, consisting of range, severity, message, and source.\n\nrange::UnitRange{Int64}\nseverity::Symbol\nmessage::String\nsource::String\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaPackage","page":"Types","title":"JuliaWorkspaces.JuliaPackage","text":"struct JuliaPackage\n\nDetails of a Julia package.\n\nproject_file_uri::URI\nname::String\nuuid::UUID\ncontent_hash::UInt\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaTestEnv","page":"Types","title":"JuliaWorkspaces.JuliaTestEnv","text":"struct JuliaTestEnv\n\nDetails of a Julia test environment.\n\npackage_name::String\npackage_uri::Union{URI,Nothing}\nproject_uri::Union{URI,Nothing}\nenv_content_hash::Union{UInt,Nothing}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaProject","page":"Types","title":"JuliaWorkspaces.JuliaProject","text":"struct JuliaProject\n\nDetails of a Julia project.\n\nproject_file_uri::URI\nmanifest_file_uri::URI\ncontent_hash::UInt\ndeved_packages::Dict{String,JuliaProjectEntryDevedPackage}\nregular_packages::Dict{String,JuliaProjectEntryRegularPackage}\nstdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaProjectEntryDevedPackage","page":"Types","title":"JuliaWorkspaces.JuliaProjectEntryDevedPackage","text":"struct JuliaProjectEntryDevedPackage\n\nDetails of a Julia project entry for a developed package.\n\nname::String\nuuid::UUID\nuri::URI\nversion::String\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaProjectEntryRegularPackage","page":"Types","title":"JuliaWorkspaces.JuliaProjectEntryRegularPackage","text":"struct JuliaProjectEntryRegularPackage\n\nDetails of a Julia project entry for a regular package.\n\nname::String\nuuid::UUID\nversion::String\ngit_tree_sha1::String\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaProjectEntryStdlibPackage","page":"Types","title":"JuliaWorkspaces.JuliaProjectEntryStdlibPackage","text":"struct JuliaProjectEntryStdlibPackage\n\nDetails of a Julia project entry for a standard library package.\n\nname::String\nuuid::UUID\nversion::Union{Nothing,String}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.JuliaWorkspace","page":"Types","title":"JuliaWorkspaces.JuliaWorkspace","text":"struct JuliaWorkspace\n\nA Julia workspace, consisting of a Salsa runtime.\n\nruntime::Salsa.Runtime\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.NotebookFile","page":"Types","title":"JuliaWorkspaces.NotebookFile","text":"struct NotebookFile\n\nA notebook file, consisting of its URI and cells.\n\nuri::URI: The URI of the file.\ncells::Vector{SourceText}: The cells of the notebook as a vector of SourceText.\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.TestSetupDetail","page":"Types","title":"JuliaWorkspaces.TestSetupDetail","text":"struct TestSetupDetail\n\nDetails of a test setup.\n\nuri::URI\nname::Symbol\nkind::Symbol\ncode::String\nrange::UnitRange{Int}\ncode_range::UnitRange{Int}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.TestDetails","page":"Types","title":"JuliaWorkspaces.TestDetails","text":"struct TestDetails\n\nDetails of a test.\n\ntestitems::Vector{TestItemDetail}\ntestsetups::Vector{TestSetupDetail}\ntesterrors::Vector{TestErrorDetail}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.TestItemDetail","page":"Types","title":"JuliaWorkspaces.TestItemDetail","text":"struct TestItemDetail\n\nDetails of a test item.\n\nuri::URI\nid::String\nname::String\ncode::String\nrange::UnitRange{Int}\ncode_range::UnitRange{Int}\noption_default_imports::Bool\noption_tags::Vector{Symbol}\noption_setup::Vector{Symbol}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.TestErrorDetail","page":"Types","title":"JuliaWorkspaces.TestErrorDetail","text":"struct TestErrorDetail\n\nDetails of a test error.\n\nuri::URI\nid::String\nname::Union{Nothing,String}\nmessage::String\nrange::UnitRange{Int}\n\n\n\n\n\n","category":"type"},{"location":"types/#JuliaWorkspaces.URIs2.URI","page":"Types","title":"JuliaWorkspaces.URIs2.URI","text":"struct URI\n\nDetails of a Unified Resource Identifier.\n\nscheme::Union{Nothing, String}\nauthority::Union{Nothing, String}\npath::String\nquery::Union{Nothing, String}\nfragment::Union{Nothing, String}\n\n\n\n\n\n","category":"type"}]
}
