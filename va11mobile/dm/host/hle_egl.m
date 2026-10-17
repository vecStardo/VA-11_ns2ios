// VA-11 移植：EGL → Mac 原生 GL（NSOpenGLContext，兼容剖面）。GM 的着色器是 GLSL ES 1.00：
// 兼容剖面接受 attribute/varying/gl_FragColor，不认 precision 限定语句——glShaderSource 包装里剥掉。
// gl* 全部 dlsym 直连系统 GL；nv 驱动入口空操作（NVIDIA GL 驱动 subsdk0 因此整层不跑）。
// VA-11 port: EGL → Mac native GL (NSOpenGLContext, legacy profile). GM's shaders are GLSL ES 1.00:
// the legacy profile accepts attribute/varying/gl_FragColor but not precision qualifiers -- the glShaderSource wrapper strips them.
// gl* all resolve via dlsym to the system GL; the nv driver entry points are no-ops (so the NVIDIA GL driver subsdk0 never runs).
#include "hle_egl.h"
#include "hle.h"
#include <dlfcn.h>
#include <stdatomic.h>
#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

typedef void *EGLDisplay; typedef void *EGLContext; typedef void *EGLSurface; typedef void *EGLConfig;
typedef unsigned EGLBoolean; typedef uint32_t EGLenum;

static NSOpenGLView *g_glview;   // 前端建的 GL 视图 | the GL view created by the front end
static NSOpenGLContext *g_ctx_main;
static EGLContext g_cur_ctx;
void hle_egl_set_view(void *view) { g_glview = (__bridge NSOpenGLView *)view; }

HLE_FORCE("eglGetDisplay", "GM：EGL 默认显示 → 宿主静态句柄", EGLDisplay, h_egl_GetDisplay, void *id) { (void)id; return (EGLDisplay)0xE1D1; }
HLE_FORCE("eglInitialize", "GM：显示初始化 → 成功（GLES 2.0）", EGLBoolean, h_egl_Initialize, EGLDisplay d, int32_t *maj, int32_t *mnr) {
    (void)d; if (maj) *maj = 1; if (mnr) *mnr = 4; LOG("[egl] initialize"); return 1;
}
HLE_FORCE("eglChooseConfig", "GM：选配置 → 单一 RGBA8888 配置", EGLBoolean, h_egl_ChooseConfig, EGLDisplay d, const int32_t *attr, EGLConfig *cfgs, int32_t n, int32_t *out) {
    (void)d; (void)attr; if (out) *out = (n > 0); if (cfgs && n > 0) cfgs[0] = (EGLConfig)0xC0F0; return 1;
}
HLE_FORCE("eglCreateContext", "GM：建上下文 → NSOpenGLContext", EGLContext, h_egl_CreateContext, EGLDisplay d, EGLConfig c, EGLContext share, const int32_t *attr) {
    (void)d; (void)c; (void)share; (void)attr;
    if (!g_glview) { LOG("【红】eglCreateContext：前端还没给 GL 视图"); return NULL; }
    // 直接用 view 自带的 context：天然已挂载到视图；自建的 context 走 setView: 会在客体线程
    // 触发 AppKit 断言（EXC_BAD_INSTRUCTION）。
    // Use the view's own context: it is attached by construction; calling setView: on a freshly
    // created context from the guest thread trips an AppKit assertion (EXC_BAD_INSTRUCTION).
    NSOpenGLContext *ctx = [g_glview openGLContext] ?: [[NSOpenGLContext alloc] initWithFormat:g_glview.pixelFormat shareContext:nil];
    LOG("[egl] create context %p", ctx); return (__bridge_retained EGLContext)ctx;   // ARC 保活：客体自己管生命周期，销毁接口是空操作 | keep alive under ARC: the guest manages its lifetime; the destroy entry is a no-op
}
HLE_FORCE("eglCreateWindowSurface", "GM：窗口面 → 宿主静态面（视图由前端提供）", EGLSurface, h_egl_CreateWindowSurface, EGLDisplay d, EGLConfig c, void *win, const int32_t *attr) {
    (void)d; (void)c; (void)win; (void)attr; return (EGLSurface)0x5EAF;
}
HLE_FORCE("eglMakeCurrent", "GM：绑定上下文", EGLBoolean, h_egl_MakeCurrent, EGLDisplay d, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    (void)d; (void)draw; (void)read;
    if (!ctx) { [NSOpenGLContext clearCurrentContext]; g_cur_ctx = NULL; return 1; }
    [(__bridge NSOpenGLContext *)ctx makeCurrentContext]; g_cur_ctx = ctx; return 1;
}
HLE_FORCE("eglSwapBuffers", "GM：出图 → flushBuffer", EGLBoolean, h_egl_SwapBuffers, EGLDisplay d, EGLSurface s) {
    (void)d; (void)s;
        static long long swapno;   // DM_GLPROBE=1：第 1/100/600/1800 次上屏抓画面采样 | sample frames 1/100/600/1800
        swapno++;
        NSOpenGLContext *cur = [NSOpenGLContext currentContext];
        if (cur) {
            if (getenv("DM_GLPROBE") && (swapno == 1 || swapno == 100 || swapno == 600 || swapno == 1800)) {
                GLubyte px[16 * 16 * 3];
                GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
                glReadPixels(vp[2] / 2 - 8, vp[3] / 2 - 8, 16, 16, GL_RGB, GL_UNSIGNED_BYTE, px);
                unsigned sum = 0; for (unsigned i = 0; i < sizeof px; i++) sum += px[i];
                NSRect b = g_glview ? g_glview.bounds : NSZeroRect;
                CGSize bk = g_glview ? [g_glview convertRectToBacking:b].size : NSZeroSize;
                LOG("[glprobe] swap#%lld vp=%dx%d 均值 %u/12288 | view逻辑 %.0fx%.0f backing %.0fx%.0f",
                    swapno, vp[2], vp[3], sum, b.size.width, b.size.height, bk.width, bk.height);
            }
            glFlush(); [cur flushBuffer];
        }
        return 1;
}
HLE_FORCE("eglDestroySurface", "GM：销毁面 → 空操作", EGLBoolean, h_egl_DestroySurface, EGLDisplay d, EGLSurface s) { (void)d; (void)s; return 1; }

// ---- nv 驱动客户端：其余两条 gfx/hle_nv.c 没覆盖的（显存信息）也空操作 ----
// ---- nv driver client: the two not covered by gfx/hle_nv.c (memory info) are no-ops too ----
HLE_FORCE("_ZN2nv21GetGraphicsMemoryInfoEPNS_10MemoryInfoE", "VA-11：显存信息空", int32_t, h_nv_GetMemInfo, void *info) { (void)info; return 0; }
HLE_FORCE("_ZN2nv22DumpGraphicsMemoryInfoEv", "VA-11：不转储", void, h_nv_DumpMem, void) {}

// ---- glShaderSource：GLSL ES → 桌面兼容剖面的源码微调（剥 precision 语句、补缺失的默认精度） ----
// ---- glShaderSource: GLSL ES → desktop legacy profile source fixup (strip precision statements) ----
static int32_t h_glShaderSource_trace(uint32_t sh, int32_t n, const char **src, const int32_t *len,
                                      void *real, const char *out);   // 诊断在文件尾 | diagnostics at the file tail
static int32_t h_glShaderSource(uint32_t sh, int32_t n, const char **src, const int32_t *len) {
    static void (*real)(uint32_t, int32_t, const char **, const int32_t *); if (!real) real = dlsym(RTLD_DEFAULT, "glShaderSource");
    static char buf[8][64 << 10]; static _Atomic int slot;
    char *out = buf[atomic_fetch_add(&slot, 1) & 7]; size_t o = 0;
    for (int i = 0; i < n; i++) {
        const char *s = src[i]; size_t sl = len && len[i] >= 0 ? (size_t)len[i] : strlen(s);
        for (size_t k = 0; k < sl && o < sizeof buf[0] - 1; ) {
            // GLSL 1.20（兼容剖面）不认精度限定词：剥 precision 语句、剥 #define LOWPREC 行、
            // 把正文里的 LOWPREC 标记换成空（展开成 lowp 会直接语法错误，32 个着色器全炸）。
            // The legacy GLSL 1.20 profile rejects precision qualifiers: strip precision statements,
            // the #define LOWPREC line, and replace LOWPREC markers with nothing.
            const char *line = s + k; size_t rem = sl - k;
            if (rem >= 7 && !strncmp(line, "LOWPREC", 7) && (rem == 7 || !isalnum((unsigned char)line[7]) || line[7] == '_')) { k += 7; continue; }   // 词边界匹配 | word-boundary match
            if ((line[0] == '#') && rem >= 16 && !strncmp(line, "#define LOWPREC", 15) && (line[15] == ' ' || line[15] == '\t')) {
                const char *e = strchr(line, '\n'); k = e ? (size_t)(e - s) + 1 : sl; continue;   // 整行剥 | strip the whole line
            }
            if ((s + k == strstr(s + k, "precision")) && (k == 0 || s[k - 1] == '\n' || s[k - 1] == ';' || s[k - 1] == ' ')) {
                const char *e = strchr(s + k, ';');   // precision lowp int; 一类语句整句剥掉 | strip the whole precision statement
                if (e && e - (s + k) < 64) { k = (size_t)(e - s) + 1; continue; }
            }
            out[o++] = s[k++];
        }
        if (o < sizeof buf[0] - 1) out[o++] = '\n';
    }
    out[o] = 0;
    if (getenv("DM_GLSL_DUMP")) LOG("[glsl] patched:\n%s", out);
    h_glShaderSource_trace(sh, n, src, len, real, out);
    const char *arr[1] = { out };   // 数组按地址传——(const char **){out} 那种复合字面量传的是 out 本身，Exec 会把字符串前 8 字节当 string[0] | pass the array by address -- a (const char **){out} literal passes out itself, and Exec would read the string's first 8 bytes as string[0]
    real(sh, 1, arr, NULL);
    return 0;
}

void *hle_gl_sym(const char *name) {
    if (!strncmp(name, "egl", 3)) { void *p = dlsym(RTLD_DEFAULT, name); if (p && p != (void *)hle_gl_sym) { void *q = NULL;
        // 宿主 FORCE 表里的 egl 实现优先于系统（系统没有 egl，dlsym 找到的只会是我们自己的） | the host FORCE table wins for egl (the system has none)
        return p; } return NULL; }
    if (!strncmp(name, "gl", 2)) {
        if (!strcmp(name, "glShaderSource")) return (void *)h_glShaderSource;
        void *p = dlsym(RTLD_DEFAULT, name);
        if (!p) {
            if (!strcmp(name, "glClearDepthf")) p = dlsym(RTLD_DEFAULT, "glClearDepth");
            else if (!strcmp(name, "glDepthRangef")) p = dlsym(RTLD_DEFAULT, "glDepthRange");
        }
        if (!p) LOG("【红】gl 导入没有宿主实现：%s", name);
        return p;
    }
    return NULL;   // nv* 与其他走 HLE_FORCE 表 | nv* and others go through the HLE_FORCE table
}

// 诊断（DM_GLSL_TRACE=1）：着色器源递交的关键参数 —— 游戏传进来的数组、垫片拼好的 out、
// real 的解析结果，以及宿主线程上有没有当前 GL 上下文。
// Diagnostics (DM_GLSL_TRACE=1): key parameters of the shader source submission -- the array the
// game passed in, the shim's assembled out, real's resolution, and whether the host thread has a
// current GL context.
static int32_t h_glShaderSource_trace(uint32_t sh, int32_t n, const char **src, const int32_t *len,
                                      void *real, const char *out) {
    if (!getenv("DM_GLSL_TRACE")) return 0;
    NSOpenGLContext *cur = [NSOpenGLContext currentContext];
    Dl_info di; dladdr(real, &di);
    LOG("[glsl] sh=%u n=%d src=%p len=%p real=%p（%s） cur_ctx=%p", sh, n, src, len, real, di.dli_sname ?: "?", cur);
    for (int i = 0; i < n && i < 4; i++)
        LOG("[glsl]  src[%d]=%p len=%d 首字节：%.32s", i, src ? src[i] : NULL, len ? len[i] : -1, src && src[i] ? src[i] : "");
    LOG("[glsl]  out 首 48 字节：%.48s", out);
    return 1;
}
