"""
    extract_modvars(ir::String) -> Vector{Int}

Extract sizes of module-level mutable variables (ModVars) from LLVM bitcode string `ir`.

# Arguments
- `ir::String` : LLVM bitcode or native IR as a raw string.

# Returns
- `Vector{Int}` : List of integer sizes corresponding to ModVars used in the bitcode.

# Description
Scans the input string for patterns matching LLVM `.set` directives that
define module globals named like `.Ljl_global#<id>.jit` and extracts
the associated integer size value.

This is useful for identifying all ModVars referenced by the generated code.

# Example pattern matched:
`.set ".Ljl_global#42.jit", 64`
"""
function extract_modvars(ir::String)::Vector{Int}
    # length("\.set\s+"\.Ljl_global#") == 19
    regex = r"""\.set\s+"\.Ljl_global#\d+\.jit",\s+(\d+)"""
    res = [(m.match[19:end], m.captures[1]) for m in eachmatch(regex, ir)]
    sort!(res)
    return [parse(Int, m[2]) for m in res]
end

function check_if_fit(s::String, keyword::String)
    pos = findfirst(keyword, s)
    if isnothing(pos)
        return nothing
    end
    
    n = length(s)
    _end = findnext(' ', s, pos[end])
    token = s[pos[end]+1:_end]
	if all(isdigit, token)
		return nothing
	end
	return pos[1]:(pos[2]+length(token))
end

"""
    extract_llvm(method::Core.Method, ir::String; main::Bool=false) -> String

Extract and clean up the LLVM IR of a single Julia-compiled function from the full IR string `ir`.

# Arguments
- `method::Core.Method`: The Julia method to locate in the LLVM IR.
- `ir::String`: The full LLVM IR text to search within.
- `main::Bool=false`: If true, rename the function to `@main`, otherwise use the Julia function name.

# Returns
- `String`: A cleaned and rewritten IR block for the requested function, including global constants and necessary declarations.

# Notes
- Handles name mangling in `@julia_<funcname>_<id>` style.
- Rewrites global constant names for uniqueness.
- Gathers required `declare` lines and LLVM attributes for external linkage.
"""
function extract_llvm(method::Core.Method, ir::String, is_main::Bool=false)::String
    funcname = string(method.name)
    func_pattern = Regex("define .*@julia_$(funcname)_\\d+")
    m = match(func_pattern, ir)
    m === nothing && error("Function $funcname not found in IR:\n$ir")

    matched_line = m.match
    offset = m.offset + length(matched_line)

    # Construct function name and rename it if needed
    suffix = extract_suffix(matched_line)
    full_funcname = matched_line[end-(length(funcname)+length(suffix)+6):end]
    renamed = is_main ? "main" : "$funcname"
    header = replace(matched_line, full_funcname => renamed)

    # Extract full function body by matching the closing brace
    body_end = find_matching_brace(ir, offset)
    body_end == -1 && error("Function body for $funcname not found.")
    body = ir[offset:body_end]
    func_ir = header * body

    # === Handle global constants ===
    modvar_regex = VERSION ≥ v"1.11.0" ?
                  r"""^@"_j_const#\d+"\s*=.*\n"""m :
                  r"""^@_j_const\d+\s*=.*\n"""m
    modvar_lines = map(m -> m.match, eachmatch(modvar_regex, ir))

    if !isempty(modvar_lines)
        modvar_map = Dict{SubString,String}()
        renamed_modvars = String[]

        for (i, line) in enumerate(modvar_lines)
            split_pos = findnext(==(' '), line, 3) - 1
            new_name = "@\"_$(funcname)_const#$i\""
            modvar_map[line[1:split_pos]] = new_name
            push!(renamed_modvars, new_name * line[split_pos+1:end])
        end

        func_ir = join(renamed_modvars) * replace(func_ir, modvar_map...)
    end

    # === Collect external function declarations and attributes ===
    decl_pattern = r"""^declare\s+\w+\s+@([^\s(]+)"""m
    decls = String["\n"]

    for m in eachmatch(decl_pattern, ir)
        fname = m.captures[1]
        # Skip internal or known runtime functions
        if !(startswith(fname, "llvm") || startswith(fname, "ijl_gc") || startswith(fname, "ijl_box"))
            start_pos = m.offsets[1] + length(fname)
            end_pos = findnext(==('\n'), ir, start_pos)
            push!(decls, ir[start_pos - length(m.match):end_pos])
        end
    end

    # Append function attributes (if any)
    attr_pattern = r"^attributes\s+#\d+\s+=\s+\{.*\}\n"m
    append!(decls, map(m -> m.match, eachmatch(attr_pattern, ir)))

    # Fix internal @j_* names to simple @func style

    final_ir = func_ir * join(decls)
    return replace(final_ir, r"@j_([A-Za-z0-9_]+)_\d+" => s"@\1")
end

"""
    get_arg_types(m::Core.Method) -> Tuple

Extracts the argument types (excluding the function itself) from the method's signature.
"""
function get_arg_types(m::Core.Method)::Tuple
    return Tuple(m.sig.parameters[2:end])
end

"""
    gen_llvm_ir_decl(name::String, value) -> (String, String)

Generate LLVM IR definition (`@name = global ...`) and external declaration (`@name = external global ...`)
for a supported Julia constant `value` with the given `name`.

Returns a tuple `(definition::String, declaration::String)`.

Supported types:
- Float64, Float32
- Int types: Int8, Int16, Int32, Int64, Int128, and UInt counterparts
- Bool
- Ptr
- Bitstypes (immutable, non-primitive types)

Throws an error for unsupported types.
"""
function gen_llvm_ir_decl(name::String, value)
    T = typeof(value)

    if T == Float64
        return "$(name) = global double $(value), align 8\n", "$(name) = external global double\n"
    elseif T == Float32
        return "$(name) = global float $(value), align 4\n", "$(name) = external global float\n"
    elseif T == Int64 || T == UInt64
        return "$(name) = global i64 $(value), align 8\n", "$(name) = external global i64\n"
    elseif T == Int32 || T == UInt32
        return "$(name) = global i32 $(value), align 4", "$(name) = external global i32\n"
    elseif T == Int16 || T == UInt16
        return "$(name) = global i16 $(value), align 2\n", "$(name) = external global i16\n"
    elseif T == Int8 || T == UInt8
        return "$(name) = global i8 $(value), align 1\n", "$(name) = external global i8\n"
    elseif T == Bool
        return "$(name) = global i8 $(Int(value)), align 1\n", "$(name) = external global i8\n"
    elseif T == Int128 || T == UInt128
        return "$(name) = global i128 $(value), align 16\n", "$(name) = external global i128\n"
    elseif T <: Ptr
        return "$(name) = global i8* null, align 8\n", "$(name) = external global i8*\n"
    elseif !ismutabletype(T) && !isprimitivetype(T)
        N = sizeof(T)
        bytes = reinterpret(NTuple{N, UInt8}, value)
        body = join(["i8 $b" for b in bytes], ", ")
        return "$(name) = global [$N x i8] [$body], align 16\n", "$(name) = external global [$N x i8]\n"
    else
        error("Unsupported type: $T")
    end
end


"""
    replace_globals(llvm_ir::String, new_names::Vector{String}) -> String

Replace occurrences of Julia global variables in LLVM IR code with new names.

# Arguments
- `llvm_ir::String`: LLVM IR code as a string, containing global variable references.
- `new_names::Vector{String}`: New names to replace the original globals with. The number of
  globals detected in `llvm_ir` must match the length of this vector.

# Returns
- `String`: The modified LLVM IR string with global variable names replaced.

# Details
- Searches for patterns like `@"jl_global#123.jit"` in the LLVM IR.
- Each unique matched global name is mapped to a new name from `new_names` in order of appearance.
- Throws an error if the number of unique globals found does not match the number of new names provided.

"""
function replace_globals(llvm_ir::String, new_names::Vector{String})::String
    # Early return if no new names are provided
    isempty(new_names) && return llvm_ir

    # Regex pattern to match Julia global variables in LLVM IR (e.g., @"jl_global#123.jit")
    global_pattern = r"""@\"jl_global#(\d+)\.jit\""""

    # Map to hold original global name strings to their replacement names
    old_to_new = Dict{SubString{String}, String}()

    index = 0
    # Iterate over all matches of the pattern in llvm_ir
    for match in eachmatch(global_pattern, llvm_ir)
        original = match.match
        # Assign new name only if this original global hasn't been seen before
        if !haskey(old_to_new, original)
            index += 1
            # Map original global string to new name with '@' prefix
            old_to_new[original] = "@" * new_names[index]
        end
    end

    # Verify the number of found globals matches the replacements provided
    if index != length(new_names)
        error("Mismatch in global variable count: found $index but got $(length(new_names)) replacements.\nLLVM IR:\n$llvm_ir")
    end

    # Perform all replacements in the llvm_ir string
    return replace(llvm_ir, old_to_new...)
end
