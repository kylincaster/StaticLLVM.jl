#ifndef ADDLIB_H
#define ADDLIB_H
// gcc -DADDLIB_EXPORTS -shared -o addlib.dll addlib.c

// 用于导出符号（Windows特有）
#ifdef ADDLIB_EXPORTS
#define ADDLIB_API __declspec(dllexport)
#else
#define ADDLIB_API __declspec(dllimport)
#endif

// 导出的函数
ADDLIB_API int add(int a, int b);

#endif // ADDLIB_H

//#include "addlib.h"

int add(int a, int b) {
    return a + b;
}
