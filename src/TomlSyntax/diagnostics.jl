# Error codes and the diagnostic type.
#
# Names follow Base's `Base.TOML.ErrorType` wherever the semantics match, so
# the ported stdlib tests read identically. Codes Base has no equivalent for
# (it does not check control characters, UTF-8 validity, etc.) come after.

"""
    TomlErrorKind

The stable code of a [`TomlDiagnostic`](@ref). Syntax codes come from the lexer,
parser and validate pass; the table codes (`ErrDuplicatedKey`, ...) from the
semantic pass in `build_table`.
"""
@enum TomlErrorKind begin
    # Toplevel / tables
    ErrExpectedNewLineKeyValue
    ErrAddKeyToInlineTable
    ErrAddArrayToStaticArray
    ErrArrayTreatedAsDictionary
    ErrExpectedEndOfTable
    ErrExpectedEndArrayOfTable
    # Keys
    ErrExpectedEqualAfterKey
    ErrDuplicatedKey
    ErrKeyAlreadyHasValue
    ErrInvalidBareKeyCharacter
    ErrEmptyBareKey
    # Values
    ErrUnexpectedEofExpectedValue
    ErrUnexpectedStartOfValue
    ErrGenericValueError
    # Arrays
    ErrExpectedCommaBetweenItemsArray
    ErrExpectedEndOfArray
    # Inline tables
    ErrExpectedCommaBetweenItemsInlineTable
    ErrTrailingCommaInlineTable
    ErrInlineTableRedefine
    # Numbers
    ErrUnderscoreNotSurroundedByDigits
    ErrLeadingZeroNotAllowedInteger
    ErrLeadingDot
    ErrNoTrailingDigitAfterDot
    ErrTrailingUnderscoreNumber
    ErrSignInNonBase10Number
    # Date/time
    ErrParsingDateTime
    # Strings
    ErrNewLineInString
    ErrUnexpectedEndString
    ErrInvalidEscapeCharacter
    ErrInvalidUnicodeScalar
    # Not covered by Base
    ErrControlCharacterInString
    ErrControlCharacterInComment
    ErrInvalidUTF8
    ErrMultilineStringAsKey
    ErrExpectedKey
    ErrUnexpectedCharacter
end

const TOML_ERROR_MESSAGES = Dict{TomlErrorKind,String}(
    ErrTrailingCommaInlineTable             => "trailing comma not allowed in inline table",
    ErrExpectedCommaBetweenItemsArray       => "expected comma between items in array",
    ErrExpectedEndOfArray                   => "expected end of array ']'",
    ErrExpectedCommaBetweenItemsInlineTable => "expected comma between items in inline table",
    ErrExpectedEndArrayOfTable              => "expected array of table to end with ']]'",
    ErrInvalidBareKeyCharacter              => "invalid bare key character",
    ErrDuplicatedKey                        => "key already defined",
    ErrKeyAlreadyHasValue                   => "key already has a value",
    ErrEmptyBareKey                         => "bare key cannot be empty",
    ErrExpectedNewLineKeyValue              => "expected newline after key value pair",
    ErrNewLineInString                      => "newline character in single quoted string",
    ErrUnexpectedEndString                  => "string literal ended unexpectedly",
    ErrExpectedEndOfTable                   => "expected end of table ']'",
    ErrAddKeyToInlineTable                  => "tried to add a new key to an inline table",
    ErrInlineTableRedefine                  => "inline table overwrote key from other table",
    ErrArrayTreatedAsDictionary             => "tried to add a key to an array",
    ErrAddArrayToStaticArray                => "tried to append to a statically defined array",
    ErrGenericValueError                    => "failed to parse value",
    ErrLeadingZeroNotAllowedInteger         => "leading zero in integer not allowed",
    ErrUnderscoreNotSurroundedByDigits      => "underscore is not surrounded by digits",
    ErrUnexpectedStartOfValue               => "unexpected start of value",
    ErrParsingDateTime                      => "parsing date/time value failed",
    ErrTrailingUnderscoreNumber             => "trailing underscore in number",
    ErrLeadingDot                           => "floats require a leading zero",
    ErrExpectedEqualAfterKey                => "expected equal sign after key",
    ErrNoTrailingDigitAfterDot              => "expected digit after dot",
    ErrInvalidUnicodeScalar                 => "invalid unicode scalar",
    ErrInvalidEscapeCharacter               => "invalid escape character",
    ErrUnexpectedEofExpectedValue           => "unexpected end of file, expected a value",
    ErrSignInNonBase10Number                => "number not in base 10 is not allowed to have a sign",
    ErrControlCharacterInString             => "control character not allowed in string",
    ErrControlCharacterInComment            => "control character not allowed in comment",
    ErrInvalidUTF8                          => "invalid UTF-8",
    ErrMultilineStringAsKey                 => "multi-line string not allowed as key",
    ErrExpectedKey                          => "expected key",
    ErrUnexpectedCharacter                  => "unexpected character",
)

for err in instances(TomlErrorKind)
    @assert haskey(TOML_ERROR_MESSAGES, err) "$err does not have an error message"
end

"""
    TomlDiagnostic

A diagnostic with a stable [`TomlErrorKind`](@ref) code, a 1-based inclusive
byte range, a level (`:error` or `:warning`) and a message. Convertible to a
`JuliaSyntax.Diagnostic` for rendering.
"""
struct TomlDiagnostic
    code::TomlErrorKind
    first_byte::Int
    last_byte::Int
    level::Symbol
    message::String
end

function TomlDiagnostic(code::TomlErrorKind, first_byte::Integer, last_byte::Integer;
                        detail::AbstractString="", level::Symbol=:error)
    return TomlDiagnostic(code, Int(first_byte), Int(last_byte), level, TOML_ERROR_MESSAGES[code] * detail)
end

JuliaSyntax.Diagnostic(d::TomlDiagnostic) = Diagnostic(d.first_byte, d.last_byte, d.level, d.message)
JuliaSyntax.first_byte(d::TomlDiagnostic) = d.first_byte
JuliaSyntax.last_byte(d::TomlDiagnostic) = d.last_byte
JuliaSyntax.byte_range(d::TomlDiagnostic) = d.first_byte:d.last_byte
JuliaSyntax.is_error(d::TomlDiagnostic) = d.level === :error
JuliaSyntax.any_error(ds::AbstractVector{TomlDiagnostic}) = any(is_error, ds)
JuliaSyntax.show_diagnostic(io::IO, d::TomlDiagnostic, source::SourceFile) =
    show_diagnostic(io, Diagnostic(d), source)
JuliaSyntax.show_diagnostics(io::IO, ds::AbstractVector{TomlDiagnostic}, source::SourceFile) =
    show_diagnostics(io, Diagnostic[Diagnostic(d) for d in ds], source)
JuliaSyntax.show_diagnostics(io::IO, ds::AbstractVector{TomlDiagnostic}, text::AbstractString) =
    show_diagnostics(io, ds, SourceFile(text))

function Base.show(io::IO, d::TomlDiagnostic)
    print(io, "TomlDiagnostic(", d.code, ", ", d.first_byte, ":", d.last_byte, ", ",
          repr(d.level), ", ", repr(d.message), ")")
end
