# 编译器与工具
CLANG = clang
AR    = ar
# 判断是否在 Windows 下
ifeq ($(OS), Windows_NT)
    # Windows 系统
    RM = coreutils rm -f
else
    # Unix-like 系统
    RM = rm -f
endif

# 编译与优化选项（例如：-O3 表示最高优化，-g 添加调试符号）
CFLAGS = -O3 -g -Wall -Wno-override-module
LDFLAGS = 

# 目录
SRC_DIR = build
OBJ_DIR = $(build)
EXEC = hello	
LIB_NAME = lib$(EXEC).a

# 所有 .ll 文件
LL_FILES := $(wildcard $(SRC_DIR)/*.ll)

# 生成 .o 文件（放在 obj/ 目录）
OBJ_FILES := $(patsubst $(SRC_DIR)/%.ll, $(OBJ_DIR)/%.o, $(LL_FILES))

# 拆分 main 和其他 .o 文件
MAIN_OBJ := $(OBJ_DIR)/main.o
OTHER_OBJS := $(filter-out $(MAIN_OBJ), $(OBJ_FILES))

# 默认目标
all: $(EXEC)

# 创建 obj 目录（如果不存在）
$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

# .ll → .o：使用 clang 编译 .ll 文件
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.ll | $(OBJ_DIR)
	$(CLANG) $(CFLAGS) -c $< -o $@

# 打包非 main.o 为静态库
$(LIB_NAME): $(OTHER_OBJS)
	$(AR) rcs $@ $^

# 链接 main.o 和 libmylib.a 生成最终程序
$(EXEC): $(MAIN_OBJ) $(LIB_NAME)
	$(CLANG) $(LDFLAGS) -o $@ $^

# 清理所有生成文件
clean:
	$(RM) $(OBJ_DIR)/*.o $(LIB_NAME) $(EXEC)

.PHONY: all clean
