
module gc_strip
    using StaticTools
    
    mutable struct A
        a::Int
    end
    mutable struct B
        a::Int
        A::A
    end
    @noinline make_A(n::Int) = A(n)
    @noinline make_B(n::Int) = B(n, A(n+3))
    @inline function main(n::Int)
        objA = make_A(n)
        objB = make_B(n+3)
        @inbounds printf("argc = n\n\0")
        printf(c"objA.a = %d\n", objA.a)
        printf(c"objB.a = %d, objB.A.a = %d\n", objB.a, objB.A.a)
    end
    
    function _main_(n::Int, argv::Ptr{Ptr{UInt8}})
        printf(c"debug_main\n")
        main(n)
    end
end

gc_strip.main(2)