using TestItems
using TestItemRunner

@testitem "Test Basic" begin
    using StaticLLVM

    module MyMod
        const MY_REF = Ref(123)
        const MY_STR = Ref("hello")

        @noinline add(x::Int) = x + MY_REF[]
        @noinline _sub(x::Int) = x - add(x)

        module SubMod
            import ..MyMod
            sub(x::Int) = x + MyMod._sub(x)  # 这里要通过 MyMod 显式访问 _sub
            const SUB_REF = Ref(3.14)
        end
    end
    
    congfig = StaticLLVM.get_config(;
        policy = :strip_all
    )
    tmp = StaticLLVM.collect_modvar_pairs(MyMod)
    modvars = [i[2] for i in tmp] |> sort!
    modvar_map = IdDict(p[1] => p[2] for p in tmp)

    @test modvars[1].name == Symbol("MY_REF")
    @test modvars[1].mod == MyMod
    @test modvars[2].name == Symbol("SUB_REF")
    @test length(modvars) == 2

    mt = which(MyMod.SubMod.sub, (Int,))

    method_map = IdDict{Core.Method, Symbol}()
    StaticLLVM.collect_methods!(method_map, mt, false)
    methods = collect(keys(method_map))
    @test length(methods) == 3

    modinfo_map = StaticLLVM.assemble_modinfo(congfig, method_map, modvar_map)
    mods = collect(values(modinfo_map)) |> sort!
    @test length(mods) == 2
    @test mods[1].mod == MyMod
    @test length(mods[1].methods) == 2 

    sort!(mods[1].methods)
    mt = mods[1].methods[2]
    @test mt.name == Symbol("add")
    @test mt.arg_types == (Int,)
    @test mt.mangled == Symbol("_ZN5__2315MyMod3addE")
    @test mods[2].mod == MyMod.SubMod
end

@testitem "Test Static" begin
    using StaticLLVM

    mutable struct st_a
        a::Int
        b::Float64
    end
    add(x) = st_a(x+1, 0.1)
    ir = sprint(io->StaticLLVM.InteractiveUtils.code_llvm(io, add, (Int,)))
    @test StaticLLVM.is_static_code(ir) == false

    StaticLLVM.emit_llvm(add)
    StaticLLVM.emit_native(add)
end

@testitem "Load heap objects" begin
    s = "good day"
    p = pointer_from_objref(s)
    @test StaticLLVM.recover_heap_object(p) === s
    v = Ref(1)
    p = pointer_from_objref(v)
    @test StaticLLVM.recover_heap_object(p)[] == v[]
end

@testitem "GenericMemory Layout" begin
    mutable struct A 
        a::Int
        b::Float64
    end
    function Layout_test(::Type{T0}) where {T0}
        gm_T = GenericMemory{:not_atomic, T0, Core.AddrSpace{Core}(0x00)}
        addr = pointer_from_objref(gm_T) |> Ptr{UInt}
        svec = unsafe_load(addr, 3) |> Ptr{UInt} # to svec_pointer 3
        @test svec == Ptr{UInt}(pointer_from_objref(gm_T.parameters))
        T = unsafe_load(svec, 3) |> Ptr{UInt} # to second element
        @test T == Ptr{UInt}(pointer_from_objref(T0))
        layout = unsafe_load(T, 6) |> Ptr{UInt64} # to layout element
        @test layout == Ptr{UInt64}(T0.layout)
        elsize = unsafe_load(Ptr{UInt32}(layout), 1)
        @test elsize == sizeof(T0)

        name0 = T0.name
        name = unsafe_load(T, 1) |> Ptr{UInt64} # to Typename
        @test name == Ptr{Int64}(pointer_from_objref(name0))
        @test unsafe_load(name, 1) == pointer_from_objref(name0.name) |> UInt
        @test unsafe_load(name, 2) == pointer_from_objref(name0.module) |> UInt
        @test unsafe_load(name, 3) == pointer_from_objref(name0.names) |> UInt
        @test unsafe_load(name, 6) == pointer_from_objref(name0.wrapper) |> UInt
        @test unsafe_load(name, 10) == pointer_from_objref(name0.mt) |> UInt
        @test unsafe_load(Ptr{Int}(name), 12) == name0.hash
        p_n_uninitialized = Ptr{Int32}(name + 12*sizeof(Int))
        pflag = Ptr{UInt8}(p_n_uninitialized + sizeof(Int32))
        pflag2 = name + 12*sizeof(Int) + sizeof(Int32)
        @test pflag2 == pflag
        @test unsafe_load(pflag, 1) == name0.flags
    end
    Layout_test(Int)
    Layout_test(NTuple{5, Float64})
    Layout_test(A)
end

@run_package_tests
