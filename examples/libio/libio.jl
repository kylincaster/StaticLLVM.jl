module LibIO

using StaticTools

"""
    logfile(input_str::Ptr{UInt8}) -> Int

Write formatted message to file using a C-compatible pointer to string.
"""
function logfile(input_str::Ptr{UInt8})::Int
    filename = c"new.file"
    mode     = c"w"
    fmt      = c"good day = %d, good %s\n"

    GC.@preserve filename mode fmt begin
        fp = StaticTools.fopen(filename, mode)
        written = StaticTools.fprintf(fp, fmt, 1, input_str)
        StaticTools.fclose(fp)
        return written
    end
end

function logfile()::Int
    filename = c"new.file"
    mode     = c"w"
    fmt      = c"good day = %d\n"

    GC.@preserve filename mode fmt begin
        fp = StaticTools.fopen(filename, mode)
        written = StaticTools.fprintf(fp, fmt, 100)
        StaticTools.fclose(fp)
        return written
    end
end

"""
    _main_(argc::Int, argv::Ptr{Ptr{UInt8}})

Entry point to call logfile if argument exists.
"""
function _main_(argc::Int, argv::Ptr{Ptr{UInt8}})
    if argc > 0
        arg1 = Ptr{UInt8}(unsafe_load(argv, 1))
        n = logfile(arg1)
        StaticTools.printf(c"write %d chars\n", n)
    else
        StaticTools.printf(c"cannot save file without argv, argc = %d\n", argc)
    end
end
end # module

#LibIO.logfile()
#print("write logfile")
