# - `modvar_ids::Vector{Int}`: A list of module-level variable addresses (e.g., `jl_global#`) found in the LLVM IR.

mutable struct LLVM_Meta
    name::String
    headers::Vector{String}
    funcs::Vector{String}
    alias::Dict{String, String}
    addrs::IdDict{Symbol, IdDict{UInt, String}}
    decls::Dict{String, String}
    attrs::Vector{String}
    raw_ir::String
end

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
function _extract_modvars(ir::String)::Vector{Int}
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
function extract_llvm(method::Core.Method, ir::String, is_main::Bool=false)
    # Fix internal @j_* names to simple @func style
    ir = replace(ir, r"@j_([A-Za-z0-9_]+)_\d+" => s"@\1")
    
    func_pattern = r"define\s+.*?@julia_([a-zA-Z0-9_]+)_([a-zA-Z0-9]+)\(.*?$"m
    mangled_funcname = nothing
    funcname = string(method.name)

    headers = String[]
    funcs = String[] # func body
    for m in eachmatch(func_pattern, ir)
        body_end = find_matching_brace(ir, m.offset)-1
        body_end == -1 && error("Function body for match not found.")
        header_end = m.offset + length(m.match)
        header = ir[m.offset:header_end]
        decl = ir[header_end+1:body_end]
        name = "julia_$(m.captures[1])_$(m.captures[2])"
        if m.captures[1] == funcname && all(isdigit, m.captures[2])
            mangled_funcname = name
            pushfirst!(headers, header)
            pushfirst!(funcs, decl)
        else
            push!(headers, header)
            push!(funcs, decl)
        end
    end
    
    isempty(funcs) && error("Function $funcname not found in IR:\n$ir")
    mangled_funcname isa Nothing && error("Function $funcname not found in IR:\n$ir")

    renamed = is_main ? "main" : funcname
    n_funcs = length(funcs)
    @inbounds for i in 1:n_funcs
        funcs[i] = replace(funcs[i], mangled_funcname => renamed)
        headers[i] = replace(headers[i], mangled_funcname => renamed)
    end

    # === Handle global constants ===
    #modvar_regex = VERSION ≥ v"1.11.0" ?
    #              r"""^@"_j_const#\d+"\s*=.*\n"""m :
    #              r"""^@_j_const\d+\s*=.*\n"""m
    
    alias_pattern = r"^@([^\ ]+)\s*=\s(.+)$"m
    alias_map = Dict{String,String}()
    
    addrs_map = IdDict{Symbol, IdDict{UInt, String}}(
        :glob=>IdDict(),
        :generic_memory=>IdDict(),
        :unknown=>IdDict(),
    )
    addrs_name = ["jl_global#"=>:glob, "Core.GenericMemory#" =>:generic_memory, ""=>:unknown]

    constvar_matches = RegexMatch[]
    addr_pattern = r"inttoptr \(i64 (\d+) to ptr\)"
    for m in eachmatch(alias_pattern, ir)
        k, v = m.captures[1:2]
        occursin(r"\"_j_const#\d+\"", k) && (push!(constvar_matches, m), continue)
        
        m_addr = match(addr_pattern, v)
        if m_addr isa Nothing
            # if not contain an address pointer
            alias_map[k]= v
        else
            addr = parse(UInt, m_addr.captures[1])
            for (name, alias_type) in addrs_name
                if occursin(name, k) 
                    addrs_map[alias_type][addr] = k
                    break
                end
            end
        end
    end

    if !isempty(constvar_matches)
        constvar_map = Dict{SubString,String}()
        for (i, m) in enumerate(constvar_matches)
            new_name = "\"_$(funcname)_const#$i\""
            constvar_map[m.captures[1]] = new_name
            alias_map[new_name] = m.captures[2]
        end
        @inbounds for i in 1:n_funcs
            funcs[i] = replace(funcs[i], constvar_map...)
        end
    end

    # === Collect external function declarations and attributes ===
    # Skip internal or known runtime functions
    decl_pattern = r"""^declare\s+(?:[\w()]+\s+)*@(?!(llvm|ijl_gc_|ijl_box_|julia.gc_alloc_|julia.pointer_from_objref|julia.\w*_gc_frame))(.+)\(.+$"""m

    decl_map = Dict{String,String}()
    for m in eachmatch(decl_pattern, ir)
        fname = m.captures[2]
        decl_map[fname] = m.match
    end

    # Append function attributes (if any)
    attr_pattern = r"^attributes\s+#\d+\s+=\s+\{.*\}\s*$"m
    attrs = map(m -> m.match, eachmatch(attr_pattern, ir))
    return LLVM_Meta(funcname, headers, funcs, alias_map, addrs_map, decl_map, attrs, ir)
end

"""
    strip_gc_allocations(ir::String)::String

Clean up Julia IR by removing GC-related stack management and replacing `@ijl_gc_pool_alloc_instrumented` calls
with standard `malloc` calls for further IR-level optimization or analysis.

# Arguments
- `ir::String`: The input LLVM IR string generated by Julia.

# Returns
- A cleaned-up IR string with GC stack frames and pool allocation calls removed or replaced.
"""
function strip_gc_allocations(ir::String)::String
    lines = split(ir, '\n')  # Split IR into lines for processing

    # === Step 1: Identify GC object tags ===
    # Match patterns like: %"<name>.tag_addr" = ...
    tag_pat = r"""%\"([^\"]+)\.tag_addr\" ="""
    tags = String[]                 # e.g., MyType
    varnames = String[""]           # e.g., %"MyType"
    for m in eachmatch(tag_pat, ir)
        name = m.captures[1]
        push!(tags, name)
        push!(varnames, "%\"$name\"")
    end

    # Pattern to match any of the GC-allocated object names
    obj_pat = Regex(join(varnames, "|"))

    # === Step 2: Construct patterns to remove GC bookkeeping lines ===
    tag_addrs = String["%\"$(name).tag_addr\"" for name in tags]
    gc_vars = String[
        " %pgcstack\\d*( = |,)",
        " %ptls_field\\d*( = |,)",
        "%ptls_load\\d* = ",
        "%gcframe\\d*( = |,)",
        "%jlcallframe\\d*( = |,)",
        "%task.gcstack\\d*( = |,)",
        "%frame.prev\\d*( = |,)",
        "%gc_slot_addr_\\d*( = |,)"
    ]

    gc_line_pat = Regex("(" * join([tag_addrs..., gc_vars...], "|") * ")")

    # Remove lines related to GC management
    filter!(line -> !occursin(gc_line_pat, line), lines)

    # === Step 3: Replace pool alloc calls with malloc ===
    gc_func_pat = "@ijl_gc_pool_alloc_instrumented("
    for (i, line) in enumerate(lines)
        startswith(line, "declare") && break
        call_pos = findfirst(gc_func_pat, line)
        if call_pos !== nothing && occursin(obj_pat, line)
            # Backtrack to find the start of the size argument
            offset = call_pos[1] - 1
            size_start = 0
            for j in offset:-1:1
                if line[j] == '('
                    size_start = j
                    break
                end
            end
            obj_size = line[size_start+1 : offset-6]  # Extract object size
            # Replace with malloc
            lines[i] = line[1:offset] * "@malloc(i64 $obj_size)"
        end
    end

    # === Step 4: Add malloc declaration at the top ===
    malloc_decl = "declare noalias nonnull ptr @malloc(i64) \n\n"
    return malloc_decl * join(lines, "\n")
end

"""
    get_arg_types(m::Core.Method) -> Tuple

Extracts the argument types (excluding the function itself) from the method's signature.
"""
function get_arg_types(m::Core.Method)::Tuple
    return Tuple(m.sig.parameters[2:end])
end

"""
    make_modvar_def(name::String, value::T, is_const::Bool = false) -> (String, String)

Generate LLVM IR global variable definition and external declaration strings for a Julia module variable.

- `name`: The variable name to be used in LLVM IR (as `@name`).
- `value`: The Julia module variable value to represent.
- `is_const`: If true, the LLVM global is marked `constant`; otherwise, it's mutable (`global`).

Returns a tuple `(definition::String, declaration::String)` where:
- `definition` is the LLVM IR global definition string with initialization.
- `declaration` is the LLVM IR external global declaration string.

Supported Julia types for `value`:
- Floating point: Float64, Float32
- Integer types: Int8, Int16, Int32, Int64, Int128 and unsigned equivalents
- Bool
- Ptr types
- String
- Immutable bitstypes (non-primitive)

Throws an error if the type is unsupported.
"""
function make_modvar_def(value::T, is_const::Bool = false) where {T}
    attri = is_const ? "constant" :  "global"

    if T == Float64
        return "$attri double $(value), align 8\n", "external $attri double\n"
    elseif T == Float32
        return "$attri float $(value), align 4\n", "external $attri float\n"
    elseif T == Int64 || T == UInt64
        return "$attri i64 $(value), align 8\n", "external $attri i64\n"
    elseif T == Int32 || T == UInt32
        return "$attri i32 $(value), align 4", "external $attri i32\n"
    elseif T == Int16 || T == UInt16
        return "$attri i16 $(value), align 2\n", "external $attri i16\n"
    elseif T == Int8 || T == UInt8
        return "$attri i8 $(value), align 1\n", "external $attri i8\n"
    elseif T == Bool
        return "$attri i8 $(Int(value)), align 1\n", "external $attri i8\n"
    elseif T == Int128 || T == UInt128
        return "$attri i128 $(value), align 16\n", "external $attri i128\n"
    elseif T <: Ptr
        return "$attri i8* null, align 8\n", "external $attri i8*\n"
    elseif T == String
        n = sizeof(value)
        defi = """{i64, [$n x i8], i8} {i64 $n, [$n x i8]  c"$value", i8 0} , align 8\n"""
        return "$attri $defi", "external $attri {i64, [$(n+1) x i8]} \n"
    elseif ismutabletype(T)
        n = sizeof(value)
        buf = IOBuffer()
        p = pointer_from_objref(value) |> Ptr{UInt8}
        for i in 1:n
            v = unsafe_load(p, i)
            print(buf, "\\$(string(v, base=16, pad=2))")
        end
        bytes_s = String(take!(buf))
        defi = """{[$n x i8], i8} {[$n x i8] c"$bytes_s", i8 0}, align 8\n"""
        return "$attri $defi", "external $attri [$(n) x i8] \n"
    elseif !ismutabletype(T) && !isprimitivetype(T)
        N = sizeof(T)
        bytes = reinterpret(NTuple{N, UInt8}, value)
        body = join(["i8 $b" for b in bytes], ", ")
        return "$attri [$N x i8] [$body], align 16\n", "external $attri [$N x i8]\n"
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

function replace_globals(llvm::String, new_names::Vector{String}; policy::Symbol=:strict)::String
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
        if policy == :strict
            error("Mismatch in global variable count: found $index but got $(length(new_names)) replacements.\nLLVM IR:\n$llvm_ir")
        else
            @warn("Mismatch in global variable count: found $index but got $(length(new_names)) replacements.\nLLVM IR:\n$llvm_ir")
        end
    end

    # Perform all replacements in the llvm_ir string
    return replace(llvm_ir, old_to_new...)
end
