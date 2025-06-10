# docs/make.jl
using Documenter
using StaticLLVM

DocMeta.setdocmeta!(StaticLLVM, :DocTestSetup, :(using StaticLLVM); recursive=true)

makedocs(;
    modules=[StaticLLVM],
    authors="Kylincaster",
    repo="https://github.com/kylincaster/StaticLLVM.jl/blob/{commit}{path}#{line}",
    sitename="StaticLLVM.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://kylincaster.github.io/StaticLLVM.jl",
        assets=String[],
    ),
    warnonly = true,
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ]
)

deploydocs(;
    repo="github.com/kylincaster/StaticLLVM.jl",
    devbranch="main",
)

