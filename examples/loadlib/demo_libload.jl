# Install
# Pkg: dev StaticTools path

module demo_libload
    using StaticTools
    function main(N::Int)
        lib = StaticTools.dlopen(c"addlib.dll", StaticTools.RTLD_GLOBAL)
        fp_add = StaticTools.dlsym(lib, c"add")

        a = 120
        ret = StaticTools.@ptrcall fp_add(a::Int, N::Int)::Int
        printf(c"ret = %d\n", ret)
        StaticTools.dlclose(lib)
    end
    function _main_(argc::Int, argv::Ptr{Ptr{UInt8}})
        main(argc)
    end
end

demo_libload.main(4)
#main()
