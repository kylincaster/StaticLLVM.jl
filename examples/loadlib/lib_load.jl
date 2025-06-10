# Install
# Pkg: dev StaticTools path
"""
This example demonstrates the interoperability between statically compiled Julia code and 
external C libraries using `StaticLLVM`. The compiled program dynamically loads a C library 
(`addlib.dll`) from `addlib.c`, calls its `add` function, and then performs a recursive Fibonacci computation 
based on the result.

```Bash
> ./LibLoad 2 3 4 5 6
The number of arguments is 6, + 3
fib(9) = 34

> ./LibLoad 1
The number of arguments is 2, + 3
fib(5) = 5
```
"""
module LibLoad
using StaticTools

"""
    fib_recursive(n::Int) -> Int

Compute the nth Fibonacci number using recursion.
"""
function fib_recursive(n::Int)::Int
    n <= 1 && return n
    return fib_recursive(n - 1) + fib_recursive(n - 2)
end

"""
    _main_(argc::Int)

Entry point: dynamically loads `addlib.dll`, calls its `add` function,
and computes the Fibonacci number of the result.
"""
function _main_(argc::Int)
        libname = c"addlib.dll"
        lib = StaticTools.dlopen(libname, StaticTools.RTLD_GLOBAL)
        if lib == C_NULL
            printf(c"cannot load addlib.dll, please compile addlib.c first!")
            return -1
        end

        fp_add = StaticTools.dlsym(lib, c"add")
        if fp_add == C_NULL
            printf(c"Function `add` not found in %d, %s\n", pointer(libname))
            return 1
        end

        n = StaticTools.@ptrcall fp_add(argc::Int, 3::Int)::Int
        printf(c"The number of arguments is %d + %d = %d\n", argc, 3, n)
        ret = fib_recursive(n)
        printf(c"fib(%d) = %d\n", n, ret)
        return 0
end

end # Module

LibLoad._main_(4)
#main()
