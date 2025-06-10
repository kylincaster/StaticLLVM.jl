# StaticLLVM

[English](./README.md)  
**StaticLLVM.jl** 是一个可以将 Julia 代码翻译并转换为静态 LLVM IR（中间表示）并生成可独立运行程序的库。

[![Docs][docs-dev-img]][docs-dev-url]  
[![CI][ci-img]][ci-url]

## Julia 内部 LLVM IR 代码转换器

**StaticLLVM.jl** 提供了一个轻量级框架，用于分析和修改由 Julia 内部函数生成的 LLVM IR。它通过识别并替换特定的结构（如与垃圾回收相关的指令或 Julia 内建函数）为标准等价物（如 `malloc`、`printf` 等）来实现对 Julia 生成的 IR 的转换。

> 🚧 **注意**：本项目正在积极开发中，许多组件仍处于实验阶段或不完整，欢迎反馈和贡献！

---

## ✨ 主要功能

- 🔧 **LLVM IR 生成**：通过 Julia 内部编译管线将 Julia 函数编译成 LLVM IR。  
- 🧠 **IR 转换引擎**：  
  - 识别并替换特定的 Julia 内部函数（如垃圾回收调用）。  
  - 将检测到的模块级变量（全局变量/常量）插入 IR。  
  - 用标准 C 库调用（如 `malloc`、`printf`）替换 Julia 内建函数。  
  - 消除或简化与垃圾回收相关的指令。  
- 🧹 **IR 清理与优化**：  
  - 去除不必要的元数据，简化 IR。  
  - 准备 IR 以便进行外部链接或嵌入本地运行时环境。  
- 📦 **简易替换库**（计划中）：  
  - 提供部分 Julia 内建函数的 C 风格实现，支持独立使用。

---

## 📁 项目结构

```
project-root/
├── examples/           # 演示脚本示例
├── src/                # 源代码
├── test/               # 测试代码
├── doc/                # 文档
└── README.md           # 项目说明文件
```

---

## 🚀 快速开始

### 先决条件

- Julia（当前测试版本为 v1.11.5）  
- Clang 或兼容的编译器（例如 Intel oneAPI、AMD 编译器）

### 示例

```julia
# ------ Example.jl ------
module Example
    using StaticTools

    function fib(n::Int)::Int
        n <= 1 && return 1
        n == 2 && return 1
        return fib(n - 1) + fib(n - 2)
    end

    const n_global = Ref(5)

    function _main_(n::Int)::Int
        n += n_global[]
        arr = Array{Int, 1}(undef, n)
        @inbounds for i in 1:n
            arr[i] = fib(i)
        end
        for i in eachindex(arr)
            @inbounds printf("fib[%d] = %d\n", i, arr[i])
        end
        return 0
    end
end

Example._main_(3)

# ------ make.jl ------

using StaticLLVM

# include("Example.jl") 或 using Example

config = StaticLLVM.get_config(;
    dir = ".",                  # 工作目录
    compile_mode = :onefile,    # 将所有 LLVM .ll 文件编译成单个二进制
    clean_cache = false,        # 保留中间缓存文件
    debug = false,              # 以 `.debug_ll` 格式导出原始 LLVM IR
    policy = :strip_all,        # 去除垃圾回收代码，使用 malloc 进行内存分配
    clang = "clang",            # clang 编译器路径
    cflag = "-O3 -g -Wall",     # clang 优化和警告标志
)

build(Example, config)
```

这样会生成一个独立的可执行程序 `Example`。

```bash
> Example 1
fib[1] = 1
fib[2] = 1
fib[3] = 2
fib[4] = 3
fib[5] = 5
fib[6] = 8
fib[7] = 13
```

实际使用流程：

1. 将程序定义为 Julia 模块。  
2. 使用 `include(...)` 或 `using` 加载模块。  
3. 调用 `build(MyModule, config)` 生成并（可选）编译 LLVM IR。

函数 `_main_()` 将作为 LLVM 程序的入口点。

---

## 📌 发展计划

- [x] 基础 IR 模式替换（Julia 内建函数 → 标准库）  
- [x] 垃圾回收代码消除与替换  
- [ ] 错误处理和诊断  
- [ ] 构建独立运行时支持库 `libcjulia`  
- [ ] 添加单元测试和持续集成支持  
- [ ] 支持跨平台的 IR 目标  

---

## 🤝 贡献指南

欢迎贡献！欢迎提 issue、建议功能或提交 PR。

---

## 📜 许可证

本项目采用 MIT 许可证。

---

## 🧠 致谢

受 Julia 基于 LLVM 的编译模型启发，本项目提供了一个极简工具链，用于在 Julia 运行时外编译和运行类似 Julia 的程序。

---

## 🔗 相关项目

- [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) – 基于 **GPUCompiler.jl** 的 Julia 静态编译器。  
- [StaticTools.jl](https://github.com/...) – 支持静态 Julia 编译的 C 互操作工具库。  
- [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) – 用于 Julia GPU 后端的可复用编译器基础设施。  

- [LLVM.jl](https://github.com/maleadt/LLVM.jl) – LLVM 编译器基础设施的 Julia 低级绑定。  
- [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) – 将整个 Julia 应用或库编译为系统镜像。  

- [ObjectOriented.jl](https://github.com/Suzhou-Tongyuan/ObjectOriented.jl) - Julia 的面向对象编程库  
- [SyslabCC-JuliaAOT](https://github.com/Suzhou-Tongyuan/SyslabCC-JuliaAOT) - SyslabIC 项目中提供的针对类型稳定 Julia 程序的提前编译（AOT）编译器  
- [Accessors.jl](https://github.com/JuliaObjects/Accessors.jl) - 用于方便且函数式更新 Julia 不可变数据结构的库  

---

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://brenhinkeller.github.io/StaticTools.jl/dev/
[ci-img]: https://github.com/brenhinkeller/StaticTools.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/brenhinkeller/StaticTools.jl/actions/workflows/CI.yml
