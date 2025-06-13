using StaticLLVM

include("./lib_load.jl")

config = StaticLLVM.get_config(;
    dir=".",
    compile_mode=:onefile,
    clean_cache = false
)

# compile mode = onefile, makefile
# clean = true or false
build(LibLoad, config)