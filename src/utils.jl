
"""
    pyprint(args...; sep=" ", tail="\n")

Print multiple arguments joined by a separator and ending with a specified tail string.

# Arguments
- `args...`: A variable number of arguments to be printed.
- `sep`: Separator string inserted between arguments. Default is a single space `" "`.
- `tail`: String appended at the end of the output. Default is newline `"\n"`.

# Behavior
- Converts all arguments to strings.
- Joins them with the separator.
- Prints the resulting string followed by the tail string.

# Example
```julia
pyprint("Hello", "world", 123; sep=", ", tail="!\n")
# Output: Hello, world, 123!
```
"""
function pyprint(args...; sep::AbstractString=" ", tail::AbstractString="\n")
    output = join(string.(args), sep)
    print(output * tail)
end

"""
    find_matching_brace(s::String, start_pos::Int=1) -> Int

Finds the index of the closing brace '}' that matches the first opening brace '{' 
found at or after `start_pos` in the string `s`.

Returns the index of the matching closing brace, or -1 if:
- No opening brace is found at or after `start_pos`, or
- Braces are unbalanced and a match can't be found.

# Arguments
- `s`: The input string to search.
- `start_pos`: The position in the string to start searching from (1-based). Defaults to 1.

# Example
```julia
find_matching_brace("a{b{c}d}e")  # returns 9
find_matching_brace("abc", 1)     # returns -1
```
"""
function find_matching_brace(s::String, start_pos::Int=1)::Int
    open_idx = findnext(==('{'), s, start_pos)
    open_idx === nothing && return -1

    depth = 0
    for i in open_idx:length(s)
        c = s[i]
        if c == '{'
            depth += 1
        elseif c == '}'
            depth -= 1
            if depth == 0
                return i
            end
        end
    end

    return -1  # No matching closing brace found
end


"""
    strip_comments(ir::String) -> String

Removes comments and trailing whitespace from LLVM IR code lines, while preserving 
leading indentation and empty lines with no code content.

# Arguments
- `ir`: A multiline string containing LLVM IR code.

# Returns
- A new string where each line has comments (starting with `;`) and trailing spaces removed.
- Lines that contain only whitespace or comments are omitted.

# Details
- The function splits the input text into lines.
- For each line, it finds the first comment delimiter `;`.
- It keeps only the part of the line before the comment.
- Trailing whitespace is trimmed, but leading whitespace (indentation) is preserved.
- Empty or whitespace-only lines after stripping are skipped.
- The resulting lines are joined back with newline characters.

# Example
```julia
code = \"\"\"
define i32 @main() {
  %1 = add i32 1, 2 ; addition
  ret i32 %1 ; return value
}
\"\"\"
println(strip_comments(code))
# Output:
# define i32 @main() {
#   %1 = add i32 1, 2
#   ret i32 %1
# }
```
"""
function strip_comments(ir::String)::String
    lines = split(ir, '\n', keepempty=true) # Split IR code into lines, preserve empty lines
    cleaned_lines = String[] # Container for processed lines
    for line in lines
        comment_pos = findfirst(==(';'), line)             # Find first ';' indicating comment
        code_part = comment_pos === nothing ? line : line[1:comment_pos-1]  # Strip comment

        # Trim trailing spaces, keep leading spaces (indentation)
        # Skip line if only whitespace remains
        if !isempty(strip(code_part))
            push!(cleaned_lines, rstrip(code_part))
        end
    end

    return join(cleaned_lines, "\n")  # Rejoin cleaned lines with newline
end


"""
    emit_llvm(method::Core.Method; clean::Bool=true, dump::Bool=true) -> String

Generate the LLVM IR for a given Julia method.

# Arguments
- `method`: The `Core.Method` object to generate LLVM IR for.
- `clean`: If `true`, strip comments and optionally prepend a header comment. Default is `true`.
- `dump`: If `true`, include the full LLVM module in the output. Default is `true`.

# Returns
- A string containing the LLVM IR of the method. When `clean` is `true`, comments are stripped.

# Details
- Extracts the function instance and argument types from the method signature.
- Uses `InteractiveUtils.code_llvm` to get the LLVM IR as a string.
- Optionally cleans the IR by removing comments using `strip_comments`.
- When cleaning, adds the method signature as a header comment.

# Example
```julia
ir = emit_llvm(my_method, clean=true, dump=false)
println(ir)
```
"""
function emit_llvm(method::Core.Method; clean::Bool=true, dump::Bool=true)::String
    fn = method.sig.parameters[1].instance # Extract function instance
    args = Tuple(method.sig.parameters[2:end]) # Extract argument types
    raw_ir = sprint(io -> InteractiveUtils.code_llvm(io, fn, args, dump_module=dump))

    if clean
        return strip_comments(raw_ir)
    else
        return raw_ir
    end
end


"""
    emit_llvm(fn::Function, args::Union{Tuple, Nothing}=nothing; clean::Bool=true, dump::Bool=true) -> String

Generate LLVM IR for a specific method of a Julia function specialized on given argument types.

# Arguments
- `fn`: Julia function whose LLVM IR is requested.
- `args`: Tuple of argument types specifying the method specialization; 
          if `nothing`, expect exactly one method for `fn`.
- `clean`: Remove extraneous comments and optionally add header if true (default: true).
- `dump`: Include full LLVM module in output if true (default: true).

# Returns
- LLVM IR string of the matched method, optionally cleaned.

# Behavior
- If `args` is provided, use `which` to find the exact method.
- If `args` is `nothing`, expect `fn` to have exactly one method, or throw an error.
- Delegates actual IR emission to another `emit_llvm` method accepting a `Method`.

# Example
```julia
ir = emit_llvm(sin, (Float64,); clean=true, dump=false)
println(ir)

add(x::Int) = x + 1
ir = emit_llvm(add)
println(ir)
```
"""
function emit_llvm(fn::Core.Function, args::Union{Tuple, Nothing}=nothing; clean::Bool=true, dump::Bool=true)::String
    method = if args isa Nothing
        all_methods = methods(fn)
        n = length(all_methods)
        n == 1 ? all_methods[1] : error("Ambiguous method: function $fn has $n methods.\nCandidates:\n$all_methods")
    else
        which(fn, args) # Find method matching function and argument types
    end
    return emit_llvm(method; clean=clean, dump=dump)
end

"""
    emit_native(method::Core.Method; clean::Bool=true, dump::Bool=true) -> String

Generate the native LLVM bitcode (assembly) for a given Julia method.

# Arguments
- `method`: The `Core.Method` to generate native code for.
- `clean`: If `true`, remove comments and debug info from the output. Default is `true`.
- `dump`: If `true`, include the full module dump. Default is `true`.

# Returns
- A string containing the native LLVM assembly code.
- When `clean` is `true`, comments and debug info are removed.

# Details
- Extracts the function instance and argument types from the method signature.
- Calls `InteractiveUtils.code_native` to get native LLVM assembly.
- Controls debug info level: `:none` if clean, otherwise `:default`.
- Optionally cleans the output by stripping comments.

# Example
```julia
native_ir = emit_native(my_method, clean=true, dump=false)
println(native_ir)
```
"""
function emit_native(method::Core.Method; clean::Bool=true, dump::Bool=true)::String
    fn = method.sig.parameters[1].instance # Function instance
    args = Tuple(method.sig.parameters[2:end]) # Argument types tuple
    debug_level = clean ? :none : :default # Debug info setting based on clean flag
    raw_native = sprint(io -> InteractiveUtils.code_native(io, fn, args, debuginfo=debug_level, dump_module=dump))

    return clean ? strip_comments(raw_native) : raw_native
end

"""
    emit_native(fn::Function, args::Union{Tuple, Nothing}=nothing; clean::Bool=true, dump::Bool=true) -> String

Generate native LLVM assembly for a specific method of a Julia function given argument types.

# Arguments
- `fn`: Julia function whose LLVM IR is requested.
- `args`: Tuple of argument types specifying the method specialization; 
          if `nothing`, expect exactly one method for `fn`.
- `clean`: Remove extraneous comments and optionally add header if true (default: true).
- `dump`: Include full LLVM module in output if true (default: true).

# Returns
- A string containing the native LLVM assembly code.
- When `clean` is `true`, comments and debug info are removed.

# Behavior
- If `args` is provided, use `which` to find the exact method.
- If `args` is `nothing`, expect `fn` to have exactly one method, or throw an error.
- Delegates actual IR emission to another `emit_llvm` method accepting a `Method`.

# Example
```julia
ir = emit_native(sin, (Float64,); clean=true, dump=false)
println(ir)

add(x::Int) = x + 1
ir = emit_native(add)
println(ir)
```
"""
function emit_native(fn::Core.Function, args::Union{Tuple, Nothing}=nothing; clean::Bool=true, dump::Bool=true)::String
    method = if args isa Nothing
        all_methods = methods(fn)
        n = length(all_methods)
        n == 1 ? all_methods[1] : error("Ambiguous method: function $fn has $n methods.\nCandidates:\n$all_methods")
    else
        which(fn, args) # Find method matching function and argument types
    end
    return emit_native(method; clean=clean, dump=dump)
end

"""
    extract_suffix(s::AbstractString) -> Union{String, Nothing}

Extract the substring after the last underscore `_` in the given string `s`.

# Arguments
- `s`: Input string.

# Returns
- The suffix substring after the last underscore.
- Returns `nothing` if there is no underscore in the string.

# Example
```julia
extract_suffix("file_name_suffix")  # returns "suffix"
extract_suffix("filename")          # returns nothing
```
"""
@inline function extract_suffix(s::AbstractString)
    pos = findlast(==('_'), s)
    return pos === nothing ? nothing : s[pos+1:end]
end


"""
    get_mod_filepath(mod::Module) -> Symbol

Retrieve the source file path symbol where the given module `mod` is defined.

# Arguments
- `mod::Module` : The Julia module to inspect.

# Returns
- `Symbol` : The source file path as a Symbol if found.

# Behavior
1. Checks if the module has a special field `:_source_file_` and returns it if present.
2. Otherwise, scans module names (excluding some built-ins) to find a function
   defined solely in this module and returns the file path of that function's method.
3. Throws an error if no suitable source file path is found.

# Notes
- Skips imported names and private names starting with `#`.
- Excludes names like `:eval` and `:include` to avoid common standard functions.
"""
function get_mod_filepath(mod::Module)::Symbol
    names_in_mod = names(mod; all=true, imported=false)

    # Check for explicit source file marker
    if :_source_file_ in names_in_mod
        return Symbol(getfield(mod, :_source_file_))
    end

    excluded_names = (:eval, :include)

    for nm in names_in_mod
        # Skip private/internal names starting with '#'
        startswith(String(nm), "#") && continue

        # Skip excluded standard names
        if !(nm in excluded_names)
            obj = getfield(mod, nm)

            # Look for a function defined exclusively in this module
            if obj isa Core.Function
                meths = methods(obj)
                if length(meths) == 1 && meths[1].module == mod
                    return meths[1].file
                end
            end
        end
    end

    error("Cannot find file path for Module: $(mod)")
end
