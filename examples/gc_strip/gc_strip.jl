"""
This example demonstrates how `StaticLLVM` enables heap allocation of mutable Julia objects 
by stripping GC-related metadata and inserting `malloc` calls instead.
It also demostrate the ability to hanlde (link) the explicit mutable-level variables `const k` 
and implicty String constant `"start program\n"`

```bash
> ./GCStrip 1 2 3 4 5
start program
argc = 6, const k = 10
objA.a = 6
objB.a = 9, objB.A.a = 12
```
"""

module GCStrip

using StaticTools

# Define user-defined mutable types
mutable struct A
    a::Int
end

mutable struct B
    a::Int
    A::A
end

# Global constant reference
const k = Ref(10)

# Object construction functions
@noinline make_A(n::Int) = A(n)
@noinline make_B(n::Int) = B(n, A(n + 3))

@inline function main(n::Int)
    objA = make_A(n)
    objB = make_B(n + 3)

    @inbounds printf("argc = %d, const k = %d\n", n, k[])
    printf(c"objA.a = %d\n", objA.a)
    printf(c"objB.a = %d, objB.A.a = %d\n", objB.a, objB.A.a)
end

function _main_(n::Int, argv::Ptr{Ptr{UInt8}})
    printf("start program\n")
    main(n)
    return 0
end

end # module

GCStrip.main(2)
