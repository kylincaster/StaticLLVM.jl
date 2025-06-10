# StaticLLVM.jl

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

## Installation

```julia
using StaticLLVM
using YourPackageName
build(YourPackageName.some_module)
```

### Prerequisites

- Julia (currently tested on v1.11.5)
- Clang or compatible compiler (e.g., Intel oneAPI, AMD compiler)

## Example

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



