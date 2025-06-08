using StaticLLVM
include("gc_strip.jl")

config = StaticLLVM.get_config(;
    dir=".",
    compile_mode=:onefile,
    clean_cache = false,
    debug = true,
    policy = :strip_all
)

# compile mode = onefile, makefile
# clean = true or false
build(gc_strip, config)
