"""
    patch_memory_instance!(blocks_map::Dict{Symbol, LLVMBlock}, block::LLVMBlock) -> Bool

Patch the LLVM IR of a block to replace a specific `Core.GenericMemory` atomic load
instruction and simplify its associated conditional branch logic.

# Arguments
- `blocks_map`: A dictionary mapping basic block names (as `Symbol`) to `LLVMBlock` objects.
- `block`: The LLVM block whose IR may contain a `Core.GenericMemory` load instruction.

# Returns
- `true` if the block was modified, `false` otherwise.

# Description
This function searches for a specific pattern in the LLVM IR indicating the use of a 
hard-coded atomic `load` from `Core.GenericMemory#<id>.jit`. If found, the instruction
is replaced with a cast from a globally defined pointer `@GenericMemoryInstance`.
The jump logic immediately following the load is also simplified to jump unconditionally
to the "success" label.

This is a low-level IR patching utility meant to canonicalize memory access logic.
"""
function patch_memory_instance!(blocks_map::IdDict{Symbol,LLVMBlock}, block::LLVMBlock)::Bool
    # Pattern matching a known atomic load to Core.GenericMemory
    load_pattern = r"\(ptr,\s*ptr\s+@\"\+Core\.GenericMemory#(\d+)\.jit\",\s*i64\s+4\)"
    jump_pattern = r"br\s+i1\s+%([\w\.]+),\s+label\s+%(fail\d*),\s+label\s+%([\w\.]+)"

    ir = block.ir
    m = match(load_pattern, ir)
    m === nothing && return false

    lines = split(ir, '\n')
    cursor = 0

    for (i, line) in enumerate(lines)
        if 0 < m.offset - cursor < length(line) + 1
            # Try to find the SSA assignment of the load
            eq_pos = findfirst('=', line)
            if eq_pos === nothing
                error("Expected SSA form for GenericMemory load, but got:\n  $line")
            end

            # Replace the atomic load with bitcast
            lines[i] = line[1:eq_pos] * " bitcast ptr @__DefaultMemoryInstance__ to ptr"

            # Expecting a conditional branch two lines after the load
            jline = lines[i+2]
            jmatch = match(jump_pattern, jline)
            if jmatch === nothing
                error("Expected conditional branch after GenericMemory load, but got:\n  $jline")
            end

            # Replace with unconditional branch to success label
            lines[i+1] = ""
            lines[i+2] = "br label %" * jmatch.captures[3]

            # Clear the fail block's IR content
            fail_label = Symbol(jmatch.captures[2])
            blocks_map[fail_label].ir = ""

            block.ir = join(lines, '\n')
            return true
        end
        cursor += length(line) + 1
    end

    return false
end

"""
    patch_memory_alloc!(block::LLVMBlock, type_map::Vector{Pair{String, Int}}) -> Bool

Replaces the LLVM IR code that performs allocation via `jl_alloc_genericmemory` with
explicit `malloc` or `calloc` instructions, based on whether the allocated type is mutable
or abstract.

# Arguments
- `block`: An `LLVMBlock` containing the IR code.
- `type_map`: A list of `Pair{String, Int}`, mapping type IDs (e.g., `"GenericMemory#1222"`) 
  to an integer flag (0 = mutable/abstract, 1 = concrete/immutable).

# Returns
- `true` if the replacement occurred, `false` otherwise.
"""
function patch_memory_alloc!(block::LLVMBlock, memory_types::Vector{Pair{SubString{String},UInt}})
    # Match the allocation call to jl_alloc_genericmemory
    pattern = r"%([^\ ]+)\s*=\s*call ptr @jl_alloc_genericmemory\(ptr nonnull @\"\+Core\.GenericMemory#(\d+)\.jit\",\s*i64\s*%([^\ ]+)\)"
    m = match(pattern, block.ir)
    m isa Nothing && return false

    mem_var = m.captures[1]
    count_var = m.captures[3]
    memory_id_str = "\"+Core.GenericMemory#$(m.captures[2]).jit\""

    # Extract block label for naming temporaries
    block_tag = block.ir[1:findnext(':', block.ir, 1)-1]

    # Find the memory info in the provided `memory_types`
    idx = findfirst(p -> p.first == memory_id_str, memory_types)
    idx === nothing && error("Type ID $memory_id_str not found in type map")

    is_mutable_or_abstract = memory_types[idx].second == 0

    # Determine allocation parameters
    elsize = is_mutable_or_abstract ? memory_types[idx].second : sizeof(Int)
    alloc_fn = is_mutable_or_abstract ? "calloc" : "malloc"
    alloc_suffix = is_mutable_or_abstract ? ",i64 0" : ""

    # Prepare new IR code
    offset = m.offset
    end_of_line = findnext('\n', block.ir, m.offsets[3])
    end_of_line === nothing && error("IR line structure malformed")

    new_ir = """
    %"TMP::_data_size_$(block_tag)" = mul i64 %$count_var, $elsize
    %$mem_var = call ptr @malloc(i64 16)
    %"TMP::_data_ptr_$(block_tag)" = call ptr @$alloc_fn(i64 %"TMP::_data_size_$(block_tag)" $alloc_suffix)
    %"TMP::_field_ptr_$(block_tag)" = getelementptr i8, ptr %$mem_var, i64 8
    store ptr %"TMP::_data_ptr_$(block_tag)", ptr %"TMP::_field_ptr_$(block_tag)", align 8
    """

    # Replace the matched alloc call with new IR
    block.ir = block.ir[1:offset-1] * new_ir * block.ir[end_of_line:end]
    return true
end

"""
    remove_substrings(input_str::AbstractString, ranges::Vector{Tuple{Int, Int}}) -> String

Removes substrings from `input_str` specified by the list of `ranges`.

# Arguments
- `input_str`: The original string.
- `ranges`: A vector of `(start, stop)` index tuples indicating substrings to remove.

# Returns
- A new string with the specified substrings removed.

# Example
```julia
remove_substrings("Hello, world!", [(1,5), (8,8)]) # returns ", orld!"
```
"""
function remove_substrings(input_str::AbstractString, ranges::Vector{Tuple{Int,Int}})::String
    output = IOBuffer()
    pos = 1
    for (start_idx, stop_idx) in ranges
        if pos < start_idx
            print(output, input_str[pos:start_idx-1])
        end
        pos = stop_idx + 1
    end
    # Print remainder if any
    if pos <= lastindex(input_str)
        print(output, input_str[pos:end])
    end

    return String(take!(output))
end

"""
    remove_memoryref_calls(block::LLVMBlock) -> Bool

Scans the LLVM IR in `block` and removes all lines that match calls to
`@memoryref`. Returns `true` if any modifications were made.

# Arguments
- `block`: The `LLVMBlock` to process.

# Returns
- `true` if the block's IR was modified, `false` otherwise.
"""
function remove_memoryref_calls(block::LLVMBlock)::Bool
    pattern = r"call void @memoryref\(.*\)$"m
    # Collect matched (start, stop) index ranges for all matching substrings
    matched_ranges = [(m.offset, m.offset + length(m.match) - 1) for m in eachmatch(pattern, block.ir)]
    isempty(matched_ranges) && return false

    # Remove all matched substrings from the IR
    block.ir = remove_substrings(block.ir, matched_ranges)
    return true
end

"""
    replace_memory_alloc(method::MethodInfo)

Scans and patches LLVM IR in the given `method` to replace 
allocations related to `Core.GenericMemory`. 

This function:
- Extracts memory layout sizes for GenericMemory types from method metadata.
- Iterates over all LLVM functions in the method, splits them into blocks.
- For each block, attempts to patch GenericMemory instances and allocations,
  and removes calls to `@memoryref`.
- Finally updates the LLVM IR in the method with the patched blocks.

# Arguments
- `method`: A `MethodInfo` struct containing LLVM IR and metadata.

# Notes
- Relies on low-level unsafe pointer operations to inspect Julia internal data.
- Emits a warning if element size exceeds 256 bytes.
- Throws an error if no GenericMemory alias is found.
"""
function replace_memory_alloc(method::MethodInfo)
    llvm = method.llvm

    # Collect (GenericMemoryName => element_size) pairs
    genericmem_size_map = Pair{SubString{String}, UInt}[]
    for (addr, addr_name) in llvm.addrs[:generic_memory]
        svec_ptr = unsafe_load(Ptr{UInt}(addr), 3) |> Ptr{UInt}       # svec pointer
        T_ptr = unsafe_load(svec_ptr, 3) |> Ptr{UInt}                 # type pointer
        layout_ptr = unsafe_load(T_ptr, 6) |> Ptr{UInt32}             # layout pointer

        typename_ptr = unsafe_load(T_ptr, 1) |> Ptr{UInt64}           # typename pointer
        flag_ptr = Ptr{UInt8}(typename_ptr + 12 * sizeof(Int) + sizeof(Int32))
        is_mutable_or_abstract = (unsafe_load(flag_ptr, 1) & 0x3) != 0

        # Determine element size depending on mutability/abstractness
        elsize = if is_mutable_or_abstract
            # Declare calloc if not declared
            llvm.decls["calloc"] = "declare ptr @calloc(i64, i64)\n"
            0
        else
            unsafe_load(layout_ptr, 1)
        end

        if elsize > 256
            @warn "Element size ($elsize) from GenericMemory at $addr in method $method exceeds 256 bytes."
        end

        push!(genericmem_size_map, addr_name => elsize)
    end

    isempty(genericmem_size_map) && error("No Core.GenericMemory alias found for method $method:\n  $(method.alias_map)")

    # Iterate over all LLVM functions to patch them
    n_funcs = length(llvm.funcs)
    @inbounds for i in 1:n_funcs
        blocks = split_blocks(llvm.funcs[i])
        blocks_map = IdDict(block.label => block for block in blocks)

        for block in blocks
            patch_memory_instance!(blocks_map, block) && continue
            patch_memory_alloc!(block, genericmem_size_map) && continue
            remove_memoryref_calls(block)
        end

        # Add a global alias for default memory instance
        llvm.alias["__DefaultMemoryInstance__"] = "common global { i64*, i64* } zeroinitializer, align 16"

        # Update function IR with patched blocks
        llvm.funcs[i] = join((blk.ir for blk in blocks), "\n")
    end
end
