# docs/make.jl
using Documenter
using StaticLLVM

#DocMeta.setdocmeta!(StaticLLVM, :DocTestSetup, :(using StaticLLVM); recursive=true)

makedocs(
    modules=[StaticLLVM],
    sitename = "StaticLLVM.jl",
    format = Documenter.HTML(),
    remotes = nothing,
    checkdocs=:all,
    warnonly = true,
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ]
    ; debug = false,
    repo = ""
)
