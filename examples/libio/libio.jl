module LibIO

using StaticTools


"""
    logfile(input_str::Ptr{UInt8}) -> Int

Write formatted message to file using a C-compatible pointer to string.
"""
function logfile(argc::Int, argv::Ptr{Ptr{UInt8}})::Int
    filename = c"log.txt"
    mode     = c"w"
    header   = c"# write file to log.txt with %d argv\n"
    fmt      = c"%s\n"

    GC.@preserve filename mode fmt header begin
        fp = StaticTools.fopen(filename, mode)
        if fp == Ptr{StaticTools.FILE}(C_NULL)
            return -1
        end
        written = StaticTools.fprintf(fp, header, argc)
        for i in 1:argc
            p = Ptr{UInt8}(unsafe_load(argv, i))
            written += StaticTools.fprintf(fp, fmt, p)
        end
        StaticTools.fclose(fp)
        return written
    end
end

function read_file()
    filename = c"log.txt"
    mode    = c"r"
    fmt     = c"line%3d: %s \n"   
    GC.@preserve filename mode fmt begin
        fp = StaticTools.fopen(filename, mode)
        if fp == Ptr{StaticTools.FILE}(C_NULL)
            return -1
        end
        s = StaticTools.readline(fp)
        n = StaticTools.strlen(s)
        i = 1
        while(StaticTools.strlen(s) != 0)
            StaticTools.printf(fmt, i, s)
            StaticTools.free(s)
            StaticTools.readline(fp)
            i += 1
            n += StaticTools.strlen(s)
        end
        StaticTools.free(s)
        n
    end
end


"""
    _main_(argc::Int, argv::Ptr{Ptr{UInt8}})

Entry point to call logfile and read_file() if argument exists.
"""
function _main_(argc::Int, argv::Ptr{Ptr{UInt8}})
    if argc > 1
        n = logfile(argc, argv)
        if n == -1
            printf(c"cannot write `log.txt`\n")
        else
            printf(c"write %d chars\n", n)
        end
    else
        printf(c"cannot save file without zero argc.\n")
    end
    n = read_file()
    printf(c"read %d chars\n", n)
    return 0
end
end # module

"""
> ./LibIO a b c d e
write 103 chars
line  1: # write file to log.txt with 6 argv
line  2: D:\\Projects\\Julia\\StaticLLVM.jl\\examples\\libio\\LibIO
line  3: a
line  4: b
line  5: c
line  6: d
line  7: e
read 96 chars
"""

#LibIO.logfile()
#print("write logfile")
