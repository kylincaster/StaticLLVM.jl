"""
This example demonstrates `StaticLLVM`'s support for low-level file I/O in Julia, including writing 
C-style formatted strings to files and reading them back. It uses `fopen`, `fprintf`, `fclose`, 
and `readline` from `StaticTools` to simulate C-like behavior with full compatibility for static compilation.

```Bash
> ./fileIO Hello world StaticLLVM
write 116 chars
line  1: # write file to log.txt with 4 argv
line  2: Julia/StaticLLVM.jl/examples/fileIO/fileIO
line  3: Hello
line  4: world
line  5: StaticLLVM
read 111 chars
```
"""

module FileIO

using StaticTools


"""
    logfile(argc::Int, argv::Ptr{Ptr{UInt8}}) -> Int

Write formatted messages to a file using C-compatible pointers to strings.
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

"""
    read_file() -> Int

Read lines from `log.txt`, print them with line numbers, and return total character count.
"""
function read_file()::Int
    filename = c"log.txt"
    mode     = c"r"
    fmt      = c"line%3d: %s \n"

    GC.@preserve filename mode fmt begin
        fp = StaticTools.fopen(filename, mode)
        if fp == Ptr{StaticTools.FILE}(C_NULL)
            return -1
        end

        total_chars = 0
        line_num = 1

        while true
            s = StaticTools.readline(fp)
            len = StaticTools.strlen(s)
            if len == 0
                StaticTools.free(s)
                break
            end
            StaticTools.printf(fmt, line_num, s)
            total_chars += len
            StaticTools.free(s)
            line_num += 1
        end

        return total_chars
    end
end

"""
    _main_(argc::Int, argv::Ptr{Ptr{UInt8}})

Entry point for the program: logs inputs to a file and reads them back.
"""
function _main_(argc::Int, argv::Ptr{Ptr{UInt8}})::Int
    if argc > 1
        n = logfile(argc, argv)
        if n == -1
            printf(c"cannot write `log.txt`\n")
        else
            printf(c"write %d chars\n", n)
        end
    else
        printf(c"cannot save file with zero argc.\n")
    end

    n = read_file()
    printf(c"read %d chars\n", n)
    return 0
end

end # Module


#FileIO.logfile()
#print("write logfile")
