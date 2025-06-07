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

@run_package_tests
