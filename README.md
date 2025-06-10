# StaticLLVM

[中文版](./README_cn.md)
**StaticLLVM.jl** 是一个可以将 Julia 代码翻译并转换为静态 LLVM IR 中间表示并获得能独立运行的程序的库。

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]

## A Transformer for Julia Internal LLVM IR code

**StaticLLVM.jl** provides a lightweight framework for analyzing and modifying LLVM IR generated from Julia internal functions. It enables transformations on Julia-emitted IR by identifying and replacing specific constructs—such as GC-related instructions or Julia intrinsics—with standard equivalents like `malloc`, `printf`, etc.

> 🚧 **Note**: This project is under active development. Many components are experimental or incomplete. Feedback and contributions are welcome!

---

## ✨ Features

- 🔧 **LLVM IR Generation**: Compile Julia functions to LLVM IR using Julia’s internal compiler pipeline.
- 🧠 **IR Transformation Engine**:
  - Detect and replace specific internal Julia functions (e.g., GC calls).
  - Insert detected module-level variables (globals/constants) into the IR.
  - Substitute Julia intrinsics with standard C library calls (e.g., `malloc`, `printf`).
  - Eliminate or simplify GC-related instructions.
- 🧹 **IR Cleanup and Optimization**:
  - Strip unnecessary metadata and simplify the IR.
  - Prepare IR for external linking or embedding in native runtimes.
- 📦 **Minimal Replacement Library** *(planned)*:
  - Provide C-style implementations of selected Julia intrinsics for standalone use.

---

## 📁 Project Structure

```
project-root/
├── examples/           # Example scripts demonstrating usage
├── src/                # Source code
├── test/               # Tests
├── doc/                # Documentation
└── README.md           # Project README
```

---

## 🚀 Quick Start

### Prerequisites

- Julia (currently tested on v1.11.5)
- Clang or compatible compiler (e.g., Intel oneAPI, AMD compiler)

### Example

```julia
# ------ Example.jl ------
module Example
    using StaticTools

    function fib(n::Int)::Int
        n <= 1 && return 1
        n == 2 && return 1
        return fib(n - 1) + fib(n - 2)
    end

    const n_global = Ref(5)

    function _main_(n::Int)::Int
        n += n_global[]
        arr = Array{Int, 1}(undef, n)
        @inbounds for i in 1:n
            arr[i] = fib(i)
        end
        for i in eachindex(arr)
            @inbounds printf("fib[%d] = %d\n", i, arr[i])
        end
        return 0
    end
end

Example._main_(3)
# ------ make.jl ------

using StaticLLVM

# include("Example.jl") or using Example

config = StaticLLVM.get_config(;
    dir = ".",                  # Working directory
    compile_mode = :onefile,    # Compile all LLVM .ll files into a single binary
    clean_cache = false,        # Keep intermediate cached files
    debug = false,              # Dump raw LLVM IR as `.debug_ll`
    policy = :strip_all         # Strip GC code and use `malloc` for memory allocation
    clang => "clang",           # Path to the clang compiler
    cflag => "-O3 -g -Wall",    # Flags passed to clang for optimization and warnings
)

build(Example, config)
```
Thus, a standalone program `Example` is generated.
``` Bash
> Example 1
fib[1] = 1
fib[2] = 1
fib[3] = 2
fib[4] = 3
fib[5] = 5
fib[6] = 8
fib[7] = 13
```

In practice:

1. Define your program as a Julia module.
2. Use `include(...)` or `using` to load the module.
3. Run `build(MyModule, config)` to generate and optionally compile the LLVM IR.

The `_main_()` function will be used as the LLVM program entry point.

---

## 📌 Roadmap

- [x] Basic IR pattern replacement (Julia intrinsics → standard library)
- [x] GC code elimination and substitution
- [ ] Error handling and diagnostics
- [ ] Build a `libcjulia` for standalone runtime support
- [ ] Add unit tests and CI coverage
- [ ] Support for cross-platform IR targets

---

## 🤝 Contributing

We welcome contributions! Feel free to open issues, suggest features, or submit pull requests.

---

## 📜 License

This project is licensed under the MIT License.

---

## 🧠 Acknowledgements

Inspired by Julia’s LLVM-based compilation model, this project provides a minimal toolchain for compiling and running Julia-like programs outside the Julia runtime.

---

## 🔗 Related Projects

- [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) –  A Julia-based static compiler built on top of **GPUCompiler.jl**.
- [StaticTools.jl](https://github.com/...) – A companion utilities library that facilitates C interoperability for static Julia compilation.
- [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) – Reusable compiler infrastructure for targeting GPU backends in Julia.

- [LLVM.jl](https://github.com/maleadt/LLVM.jl) – Low-level Julia bindings for the LLVM compiler infrastructure.
- [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) – Compile entire Julia applications or libraries into system images.

- [ObjectOriented.jl](https://github.com/Suzhou-Tongyuan/ObjectOriented.jl) - An object-oriented programming library for Julia
- [SyslabCC-JuliaAOT](https://github.com/Suzhou-Tongyuan/SyslabCC-JuliaAOT) - An ahead-of-time (AOT) compiler for type-stable Julia programs, provide by in the SyslabIC program package
- [Accessors.jl](https://github.com/JuliaObjects/Accessors.jl) - A library for ergonomic and functional updates of immutable data structures in Julia.


[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://kylincaster.github.io/StaticLLVM.jl/dev/
[ci-img]: https://github.com/kylincaster/StaticLLVM.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/kylincaster/StaticLLVM.jl/actions/workflows/CI.yml

