
module gc_strip
    using StaticTools
    
    mutable struct A
        a::Int
    end
    mutable struct B
        a::Int
        A::A
    end
    const k = Ref(10)
    @noinline make_A(n::Int) = A(n)
    @noinline make_B(n::Int) = B(n, A(n+3))
    @inline function main(n::Int)
        objA = make_A(n)
        objB = make_B(n+3)
        @inbounds printf("argc = %d, const k = %d\n", n, k[])
        printf(c"objA.a = %d\n", objA.a)
        printf(c"objB.a = %d, objB.A.a = %d\n", objB.a, objB.A.a)
    end
    
    function _main_(n::Int, argv::Ptr{Ptr{UInt8}})
        printf(c"start program\n")
        main(n)
    end
end


"""
> ./gc_strip 1 2 3 4 5 6
start program
argc = 7, const k = 10
objA.a = 7
objB.a = 10, objB.A.a = 13
"""

gc_strip.main(2)