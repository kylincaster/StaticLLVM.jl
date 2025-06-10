
mutable struct LLVM_Block
    lable::Symbol
    ind::Int
    ir::SubString{String}
end

function split_llvm_blocks(ir::AbstractString)
    pattern = r"(?m)^\s*(\w+):"  # 匹配每个 basic block 标签，如 top: 或 L3:
    matches = collect(eachmatch(pattern, ir))

    blocks = LLVM_Block[]

    for i in 1:length(matches)
        label = Symbol(matches[i].captures[1])                 # 标签名（如 "top", "L3"）
        start = matches[i].offset                              # 当前 block 起始位置
        end_ = i < length(matches) ? matches[i+1].offset - 1 : lastindex(ir)  # 当前 block 结束位置
        block = LLVM_Block(label, i, SubString(ir, start, end_))
        push!(blocks, block)
    end
    return blocks
end


function replace_GenericMemory_instance(blocks_map, block::LLVM_Block)
    # TODO: to hanlde non-zero JL_DATA_TYPE
    pattern = r"\(ptr,\s*ptr\s+@\"\+Core\.GenericMemory#(\d+)\.jit\",\s*i64\s+4\)"
    ir = block.ir
    m = match(pattern, ir)
    m isa Nothing && return false

    lines = split(ir, "\n")
    n = 0
    pattern_jump = r"br\s+i1\s+%([\w\.]+),\s+label\s+%(fail\d*), label %([\w\.]+)"
    for (i, line) in enumerate(lines)
        if 0 < m.offset - n < length(line) + 1
            pos = findfirst('=', line)
            pos isa Nothing && error("cannot capture GenericMemory obj\n expect: ` %.instance = load atomic ptr, ptr getelementptr inbounds (ptr, ptr @\"+Core.GenericMemory#1222.jit\", i64 4) unordered, align 32`\n obtain: `$(line)`\n ")
            lines[i] = line[1:pos] * " bitcast ptr @GenericMemoryInstance to ptr"

            jline = lines[i+2]
            jmatched = match(pattern_jump, jline)
            jmatched isa Nothing && error("cannot capture GenericMemory jump\n expect: `br i1 %.not3, label %fail, label %L7`\n obtain: `$(jline)`\n ")

            lines[i+1] = ""
            lines[i+2] = "br label %" * jmatched.captures[3]
            
            block.ir = join(lines,"\n")
            blocks_map[Symbol(jmatched.captures[2])].ir = ""
            return true 
        end
        n += length(line)+1
    end
    return false
end


function replace_GenericMemory_alloc(block::LLVM_Block, pairs)
    # TODO: to hanlde non-zero JL_DATA_TYPE
    ir = block.ir
    m = match(r"%([^\ ]+)\s*=\s*call ptr @jl_alloc_genericmemory\(ptr nonnull @\"\+Core\.GenericMemory#(\d+)\.jit\",\s*i64\s*%([^\ ]+)\)", ir)
    m isa Nothing && return false

    mem = m.captures[1]
    GenericMemoryId = "\"+Core.GenericMemory#$(m.captures[2]).jit\""
    nitem = m.captures[3]
    tag = ir[1:findnext(':', ir, 1)-1]

    idx = findfirst(p -> p.first == GenericMemoryId, pairs)
    is_mutable_or_abstract = pairs[idx].second == 0 # is mutable or abstract type
    elsize, alloc, alloc_config = if is_mutable_or_abstract
        pairs[idx].second, "calloc", ",i64 0"
    else
        sizeof(Int), "malloc", ""
    end

    offset = m.offset
    pos_nextline = findnext('\n', ir, m.offsets[3])
    
    new_code = """
    %"TMP::_data_size_$(tag)" = mul i64 %$nitem, $elsize
    %$mem = call ptr @malloc(i64 16)
    %"TMP::_data_ptr_$(tag)" = call ptr @$(alloc)(i64 %"TMP::_data_size_$(tag)" $alloc_config)
    %"TMP::_field_ptr_$(tag)" = getelementptr i8, ptr %$mem, i64 8
    store ptr %"TMP::_data_ptr_$(tag)", ptr %"TMP::_field_ptr_$(tag)", align 8
    """
    block.ir = ir[1:offset-1] * new_code * ir[pos_nextline:end]
    return true
end

function delete_range(input_str::AbstractString, ranges::Vector)
    output = IOBuffer()
    pos = 1
    for (start, stop) in ranges
        if pos < start
            print(output, input_str[pos:start-1])
        end
        pos = stop + 1
    end

    if pos <= lastindex(input_str)
        print(output, input_str[pos:end])
    end

    return String(take!(output))
end

function filter_block(block::LLVM_Block)::Bool
    pattern = r"call void @memoryref\(.*\)$"m
    matches = collect((m.offset, m.offset+length(m.match)) for m in eachmatch(pattern, block.ir)) 
    isempty(matches) && return false
    block.ir = delete_range(block.ir, matches)
    return true
end

function replace_memory_alloc(method::MethodInfo)
    llvm = method.llvm
    GenericMemory_to_size = Pair{SubString{String}, UInt}[]
    for (addr, addr_name) in llvm.addrs[:generic_memory]
        svec = unsafe_load(Ptr{UInt}(addr), 3) |> Ptr{UInt} # to svec_pointer 3
        T = unsafe_load(svec, 3) |> Ptr{UInt} # to to second element
        layout = unsafe_load(T, 6) |> Ptr{UInt32} # to to layout element
            
        name = unsafe_load(T, 1) |> Ptr{UInt64} # to Typename
        pflag = Ptr{UInt8}(name + 12*sizeof(Int) + sizeof(Int32))
        is_mutable_or_abstract = (unsafe_load(pflag, 1) & 0x3) != 0
            
        # add the calloc for mutable_or_abstract
        elsize = if is_mutable_or_abstract
            llvm.decls["calloc"] = "declare ptr @calloc(i64, i64)\n"
            0
        else
            unsafe_load(layout, 1)
        end

        elsize > 256 && @warn ("Elsize ($elsize) from GenericMemory at $addr from $method, is exceed 256")
        # println(method, "elsize = ", elsize)
        push!(GenericMemory_to_size, addr_name => elsize)
    end

    isempty(GenericMemory_to_size) && error("cannot find Core.GenericMemory alias from $method:\n  $method.alias_map")

    n_funcs = length(llvm.funcs)
    @inbounds for i in 1:n_funcs
        blocks = split_llvm_blocks(llvm.funcs[i])
        blocks_map = IdDict(block.lable=>block for block in blocks)
        for block in blocks
            replace_GenericMemory_instance(blocks_map, block) && continue
            replace_GenericMemory_alloc(block, GenericMemory_to_size) && continue
            filter_block(block)
        end
        llvm.alias["GenericMemoryInstance"] = "common global { i64*, i64* } zeroinitializer, align 16"
        llvm.funcs[i] = join((blk.ir for blk in blocks), "\n")
    end
end