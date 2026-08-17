# Types

```@meta
CurrentModule = JuliaWorkspaces
```

## Core types

```@docs
JuliaWorkspace
TextFile
SourceText
Diagnostic
```

## Dynamic feature

```@docs
DynamicMode
DEFAULT_SYMBOLCACHE_UPSTREAM
DEFAULT_MAX_FAILURE_ATTEMPTS
DEFAULT_DJP_REQUEST_TIMEOUT_SECONDS
```

## Completion result types

```@docs
CompletionResult
CompletionResultItem
CompletionEdit
CompletionKinds
InsertFormats
```

## Reference, definition and rename result types

```@docs
DefinitionResult
ReferenceResult
RenameEdit
HighlightResult
```

## Signature help result types

```@docs
SignatureResult
SignatureInfo
ParameterInfo
```

## Symbol result types

```@docs
DocumentSymbolResult
WorkspaceSymbolResult
```

## Navigation result types

```@docs
SelectionRangeResult
BlockRangeResult
```

## Document link and inlay hint result types

```@docs
DocumentLinkResult
InlayHintResult
InlayHintConfig
```

## Code action result types

```@docs
CodeActionInfo
TextEditResult
WorkspaceFileEdit
```

## Configuration types

See [Configuration](configuration.md) for the file format these describe.

```@docs
LintRule
LintTier
EffectiveLintConfig
EffectiveFormatConfig
GlobPattern
PathFilter
```

## Internal types

```@docs
Position
JuliaPackage
JuliaTestEnv
JuliaProject
JuliaProjectEntryDevedPackage
JuliaProjectEntryRegularPackage
JuliaProjectEntryStdlibPackage
NotebookFile
TestSetupDetail
TestDetails
TestItemDetail
TestErrorDetail
URI
```