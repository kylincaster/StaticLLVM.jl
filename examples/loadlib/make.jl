
using StaticLLVM

include("./demo_libload.jl")

config = StaticLLVM.get_config(;
    dir=".",
    compile_mode=:onefile,
    clean_cache = false
)

# compile mode = onefile, makefile
# clean = true or false
build(demo_libload, config)