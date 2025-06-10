// To compile into library
// gcc -DADDLIB_EXPORTS -shared -o addlib.dll addlib.c

#ifndef ADDLIB_H
#define ADDLIB_H

// To Export Symbols in Windows
#ifdef _WIN32
  #ifdef ADDLIB_EXPORTS
    #define ADDLIB_API __declspec(dllexport)
  #else
    #define ADDLIB_API __declspec(dllimport)
  #endif
#else
  #define ADDLIB_API
#endif

// To Export Function
ADDLIB_API int add(int a, int b);

#endif // ADDLIB_H

//#include "addlib.h"

int add(int a, int b) {
    return a + b;
}
