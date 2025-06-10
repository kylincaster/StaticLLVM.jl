"""
This example demonstrates the ability of `StaticLLVM` to handle heap memory allocation 
for Julia arrays, including those of custom structs, tuples, and primitive types.

**Example Output:**
```bash
\$ ./Array_alloc 1 2 3 4 5
Test Dynamic Memory Allocation
x[1] = 10
length(x) = 6
length(y) = 0
length(z) = 7
length(a) = 8
```
"""
module ArrayAlloc

using StaticTools

# Define a mutable struct with mixed types
mutable struct A
    a::Int
    b::Float64
end

# Functions to allocate arrays of different types
@noinline make_struct(i::Int) = Array{A}(undef, i)
@noinline make_tuple(i::Int) = Array{NTuple{5, Int}}(undef, i)
@noinline make_float() = Float64[]
@noinline make_int(i::Int) = Array{Int}(undef, i)

function _main_(n::Int)
    @inbounds printf(c"Test Dynamic Memory Allocation\n")

    x = make_int(n)
    y = make_float()
    z = make_tuple(n + 1)
    a = make_struct(n + 2)

    if n > 0
        @inbounds x[1] = 10
        @inbounds printf(c"x[1] = %d\n", x[1])
        @inbounds printf(c"length(x) = %d\n", length(x))
        @inbounds printf(c"length(y) = %d\n", length(y))
        @inbounds printf(c"length(z) = %d\n", length(z))
        @inbounds printf(c"length(a) = %d\n", length(a))
    end

    return 0
end

end # module


ArrayAlloc._main_(3)