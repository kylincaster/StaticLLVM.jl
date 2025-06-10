"""
This example demonstrates the interoperability between statically compiled Julia code and 
external C libraries using `StaticLLVM`.  
The C-style external `printf` and `printf!` (`sprintf` from C) functions, provided from `StaticTools` is called 
with manual memory management.

```Bash
> ./PrintfDemo
Part.1 sprintf(), #argc = #3-4)
MallocString contents: Hello World
first line
second line

MallocString contents: Hello World
first line
second line
third line

Part.2 printf(), #argc = 1-4)
Hello World

 ---
Hello World
first line

 ---
Hello World
first line
second line

 ---
Hello World
first line
second line
third line
```
"""
module PrintfDemo

    using StaticTools
    @noinline function print_c1()
        fmt = c"Hello World\n\n --- \n"    
        GC.@preserve fmt printf(fmt)
    end
    @noinline function print_c2()
        fmt = c"Hello World\n%s\n --- \n"
        s1 = c"first line\n"
        GC.@preserve fmt s1 printf(fmt, s1)
    end
    @noinline function print_c3()
        fmt = c"Hello World\n%s%s\n --- \n"
        s1 = c"first line\n"
        s2 = c"second line\n"
        GC.@preserve fmt s1 s2 printf(fmt, s1, s2)
    end

    @noinline function print_c4()
        fmt = c"Hello World\n%s%s%s\n --- \n"
        s1 = c"first line\n"
        s2 = c"second line\n"
        s3 = c"third line\n"
        GC.@preserve fmt s1 s2 s3 printf(fmt, s1, s2, s3)
    end

    @noinline function sprint_c3()
        s = StaticTools.MallocString(undef, 500)
        p = s.pointer
        fmt = c"Hello World\n%s%s\n"
        s1 = c"first line\n"
        s2 = c"second line\n"
        GC.@preserve fmt s1 s2 printf!(p, fmt, s1, s2)
        printf(c"MallocString contents: %s\n", s)
    end

    @noinline function sprint_c4()
        s = StaticTools.MallocString(undef, 500)
        p = s.pointer
        fmt = c"Hello World\n%s%s%s\n"
        s1 = c"first line\n"
        s2 = c"second line\n"
        s3 = c"third line\n"
        GC.@preserve fmt s1 s2 s3 printf!(p, fmt, s1, s2, s3)
        printf(c"MallocString contents: %s\n", s)
    end

    function _main_()
        @inbounds printf("Part.1 sprintf(), #argc = #%d-%d)\n", 3, 4)
        sprint_c3()
        sprint_c4()
        
        @inbounds printf("Part.2 printf(), #argc = %d-%d)\n", 1, 4)
        print_c1()
        print_c2()
        print_c3()
        print_c4()
        
        return 0
    end
end

PrintfDemo._main_()
