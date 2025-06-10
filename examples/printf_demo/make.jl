using StaticLLVM
include("printf_demo.jl")

config = StaticLLVM.get_config(;
    dir=".",
    compile_mode=:onefile,
    clean_cache = false,
    debug=false,
    policy = :warn,
)

# compile mode = onefile, makefile
# clean = true or false
build(PrintfDemo, config)
