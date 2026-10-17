// VA-11 HALL-A 移植：GM runner 用 EGL + OpenGL ES（Switch 上由 NVIDIA GL 驱动实现）。
// 宿主把 egl* 接到原生窗口 GL 上下文（Mac：NSOpenGLContext；iOS：EAGL），gl* 直连系统 GL。
// EGL* → the native-window GL context (Mac: NSOpenGLContext; iOS: EAGL); gl* resolve straight to the system GL.
#ifndef HLE_EGL_H
#define HLE_EGL_H
#include <stdint.h>
void *hle_gl_sym(const char *name);   // 装载器导入解析：gl*/egl*/nv* → 宿主实现 | loader import resolution: gl*/egl*/nv* → host implementations
void hle_egl_set_view(void *view);    // 前端把承载 GL 的视图交给垫片（Mac：NSOpenGLView*） | front end hands the GL-bearing view to the shim (Mac: NSOpenGLView*)
#endif
