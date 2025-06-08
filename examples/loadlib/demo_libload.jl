# Install
# Pkg: dev StaticTools path

module demo_libload
    using StaticTools
    
    function fib_recursive(n::Int)::Int
        n <= 1 && return n
        return fib_recursive(n - 1) + fib_recursive(n - 2)
    end
    
    function _main_(argc::Int, argv::Ptr{Ptr{UInt8}})
        lib = StaticTools.dlopen(c"addlib.dll", StaticTools.RTLD_GLOBAL)
        if lib == C_NULL
            printf(c"cannot load addlib.dll, please compile addlib.c first!")
        end
        fp_add = StaticTools.dlsym(lib, c"add")
        n = StaticTools.@ptrcall fp_add(argc::Int, 3::Int)::Int
        printf(c"The number of arguments is %d, + %d\n", argc, 3)
        ret = fib_recursive(n)
        printf(c"fib(%d) = %d\n", n, ret)
    end
end

"""
> ./demo_libload 2 3 4 5 6
The number of arguments is 6, + 3
fib(9) = 34

> ./demo_libload 1
The number of arguments is 2, + 3
fib(5) = 5
"""

demo_libload._main_(1, Ptr{Ptr{UInt8}}(C_NULL))
#main()
