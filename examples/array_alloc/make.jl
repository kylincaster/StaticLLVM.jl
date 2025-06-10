using StaticLLVM
include("array_alloc.jl")

config = StaticLLVM.get_config(;
    dir=".",
    compile_mode=:onefile,
    clean_cache = false,
    debug = false,
    policy = :strip_all
)

# compile mode = onefile, makefile
# clean = true or false
ret = build(ArrayAlloc, config)


