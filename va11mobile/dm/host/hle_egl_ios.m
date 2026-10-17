// VA-11 iOS：EGL → EAGL / OpenGL ES 2.0。GM runner 的着色器是 GLSL ES 1.00，EAGL 本身就是 GLES，
// 所以 glShaderSource 不做源码微调（Mac 版 hle_egl.m 要把它降到桌面兼容剖面才需要剥 precision / LOWPREC）。
// 出图目标：远端（前端）给的 CAEAGLLayer；egl* 全走 HLE_FORCE，gl* 由 hle_gl_sym 直连系统 GLES。
// 关键一处：EAGL 没有「窗口默认帧缓冲」，游戏每帧会 glBindFramebuffer(GL_FRAMEBUFFER, 0) 回到默认缓冲——
// 这里把 0 换成宿主的 FBO（颜色 + 深度 renderbuffer 挂在 CAEAGLLayer 上），上屏在 eglSwapBuffers 里 present。
// VA-11 iOS: EGL → EAGL / OpenGL ES 2.0. The GM runner's shaders are GLSL ES 1.00 and EAGL *is* GLES,
// so glShaderSource gets no source fixup (the Mac version hle_egl.m needs to strip precision / LOWPREC
// only because it lowers them to the desktop legacy profile).
// Render target: the CAEAGLLayer handed over by the front end; egl* all go through HLE_FORCE, gl* is wired
// straight to the system GLES by hle_gl_sym.
// Key detail: EAGL has no "window default framebuffer", and the game binds GL_FRAMEBUFFER 0 every frame to get
// back to the default buffer -- here 0 is remapped to the host FBO (colour + depth renderbuffer attached to
// the CAEAGLLayer) and eglSwapBuffers presents it.
#include "hle_egl.h"
#include "hle.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#include <dlfcn.h>

typedef void *EGLDisplay; typedef void *EGLContext; typedef void *EGLSurface; typedef void *EGLConfig;
typedef unsigned EGLBoolean; typedef uint32_t EGLenum;

static UIView *g_glview;          // 前端建的 EAGL 视图（layerClass = CAEAGLLayer） | the EAGL view created by the front end (layerClass = CAEAGLLayer)
static EAGLContext *g_ctx;        // 宿主上下文（eglCreateContext 建） | host context (created by eglCreateContext)
static GLuint g_fbo, g_rbo, g_dbo;
static int g_ready;               // FBO 就绪（首次 MakeCurrent / Swap 时建） | FBO ready (built on the first MakeCurrent / Swap)
static long long g_swapno;

void hle_egl_set_view(void *view) { g_glview = (__bridge UIView *)view; }

// 主线程预建上下文与 FBO（前端在窗口可见后调）：EAGL 的 drawable 与 CA 合成都在主线程上建，
// 客体线程只借用这个上下文渲染，避免「后台线程建的 drawable 上不了屏」这类差异。
// Pre-build the context and FBO on the main thread (the front end calls this once the window is visible): the EAGL
// drawable and the CA composite are both created on the main thread, and the guest thread only renders with this
// context, avoiding "a drawable created on a background thread does not reach the screen" differences.
static int ensure_target(void);   // 定义在下面 | defined below
int hle_egl_prepare_on_main(void) {
    if (!g_glview) { LOG("【红】[egl] prepare：前端还没给 GL 视图"); return 0; }
    if (!g_ctx) g_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!g_ctx) { LOG("【红】[egl] prepare：建不出 EAGLContext"); return 0; }
    int ok = ensure_target();   // 内部会 setCurrentContext + 建 FBO | internally sets the context current and builds the FBO
    LOG("[egl] 主线程预建：%s", ok ? "OK" : "失败");
    return ok;
}

// 建 FBO：颜色 renderbuffer 经 renderbufferStorage:fromDrawable: 直接挂到视图的 CAEAGLLayer 上（present 时把这块画布
// 交给系统合成），深度另挂一个 16 位 renderbuffer。只能在上下文已 current 的线程上调。
// Build the FBO: the colour renderbuffer is attached to the view's CAEAGLLayer through
// renderbufferStorage:fromDrawable: (presenting hands this canvas to the system compositor), and a 16-bit depth
// renderbuffer is attached separately. Must be called on the thread where the context is current.
static int ensure_target(void) {
    if (g_ready) return 1;
    if (!g_ctx) { LOG("【红】[egl] 还没有上下文"); return 0; }
    if (!g_glview) { LOG("【红】[egl] 前端还没给 GL 视图"); return 0; }
    CAEAGLLayer *layer = (CAEAGLLayer *)g_glview.layer;
    if (![layer isKindOfClass:[CAEAGLLayer class]]) { LOG("【红】[egl] 视图的层不是 CAEAGLLayer"); return 0; }
    layer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8 };
    [EAGLContext setCurrentContext:g_ctx];
    glGenFramebuffers(1, &g_fbo); glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glGenRenderbuffers(1, &g_rbo); glBindRenderbuffer(GL_RENDERBUFFER, g_rbo);
    if (![g_ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) { LOG("【红】[egl] renderbufferStorage:fromDrawable: 失败（drawable 尺寸 %.0fx%.0f）", layer.bounds.size.width, layer.bounds.size.height); return 0; }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g_rbo);
    GLint w = 0, h = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
    if (w <= 0 || h <= 0) { LOG("【红】[egl] 画布 %dx%d", w, h); return 0; }
    glGenRenderbuffers(1, &g_dbo); glBindRenderbuffer(GL_RENDERBUFFER, g_dbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_dbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g_rbo);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (st != GL_FRAMEBUFFER_COMPLETE) { LOG("【红】[egl] FBO 不完整 %#x", st); return 0; }
    g_ready = 1;
    LOG("[egl] EAGL 就绪：%dx%d（视图 %.0fx%.0f）", w, h, g_glview.bounds.size.width, g_glview.bounds.size.height);
    return 1;
}

// glBindFramebuffer 的宿主包装：0 → 宿主 FBO（见文件头）。其余 id 原样透传。
// Host wrapper for glBindFramebuffer: 0 -> the host FBO (see the file header). All other ids pass through.
static void (*g_real_bind_fb)(GLenum, GLuint);
static void h_glBindFramebuffer(GLenum target, GLuint fb) {
    if (!g_real_bind_fb) g_real_bind_fb = (void (*)(GLenum, GLuint))dlsym(RTLD_DEFAULT, "glBindFramebuffer");
    if (!g_real_bind_fb) return;
    if (target == GL_FRAMEBUFFER && fb == 0) fb = g_fbo;
    g_real_bind_fb(target, fb);
}

// ---- EGL：与 Mac 版逐条对应，只是上下文换成 EAGLContext、上屏换成 presentRenderbuffer ----
// ---- EGL: one entry per Mac entry; only the context becomes an EAGLContext and presenting becomes presentRenderbuffer ----
HLE_FORCE("eglGetDisplay", "VA-11 iOS：EGL 默认显示 → 宿主静态句柄", EGLDisplay, h_egl_GetDisplay, void *id) { (void)id; return (EGLDisplay)0xE1D1; }
HLE_FORCE("eglInitialize", "VA-11 iOS：显示初始化 → 成功（GLES 2.0）", EGLBoolean, h_egl_Initialize, EGLDisplay d, int32_t *maj, int32_t *mnr) {
    (void)d; if (maj) *maj = 2; if (mnr) *mnr = 0; LOG("[egl] initialize（GLES 2.0）"); return 1;
}
HLE_FORCE("eglChooseConfig", "VA-11 iOS：选配置 → 单一 RGBA8888 配置", EGLBoolean, h_egl_ChooseConfig, EGLDisplay d, const int32_t *attr, EGLConfig *cfgs, int32_t n, int32_t *out) {
    (void)d; (void)attr; if (out) *out = (n > 0); if (cfgs && n > 0) cfgs[0] = (EGLConfig)0xC0F0; return 1;
}
HLE_FORCE("eglCreateContext", "VA-11 iOS：EGL 上下文 → EAGLContext（GLES2）", EGLContext, h_egl_CreateContext, EGLDisplay d, EGLConfig c, EGLContext share, const int32_t *attr) {
    (void)d; (void)c; (void)share; (void)attr;
    if (!g_glview) { LOG("【红】eglCreateContext：前端还没给 GL 视图"); return NULL; }
    if (!g_ctx) { g_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2]; if (!g_ctx) { LOG("【红】[egl] EAGLContext 建不出来"); return NULL; } }
    LOG("[egl] create context %p", g_ctx);
    void *keep = (__bridge_retained void *)g_ctx;   // 保活：销毁接口是空操作，进程活到退出 | keep alive: destroy is a no-op, the process lives until exit
    return (EGLContext)keep;
}
HLE_FORCE("eglCreateWindowSurface", "VA-11 iOS：窗口面 → 宿主静态面（出图目标是前端的 CAEAGLLayer）", EGLSurface, h_egl_CreateWindowSurface, EGLDisplay d, EGLConfig c, void *win, const int32_t *attr) {
    (void)d; (void)c; (void)win; (void)attr; return (EGLSurface)0x5EAF;
}
HLE_FORCE("eglMakeCurrent", "VA-11 iOS：绑定上下文（并首次建 FBO）", EGLBoolean, h_egl_MakeCurrent, EGLDisplay d, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    (void)d; (void)draw; (void)read;
    if (!ctx) { [EAGLContext setCurrentContext:nil]; return 1; }
    g_ctx = (__bridge EAGLContext *)ctx;
    [EAGLContext setCurrentContext:g_ctx];
    if (!ensure_target()) return 0;
    g_real_bind_fb ? g_real_bind_fb(GL_FRAMEBUFFER, g_fbo) : glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    return 1;
}
HLE_FORCE("eglSwapBuffers", "VA-11 iOS：出图 → presentRenderbuffer", EGLBoolean, h_egl_SwapBuffers, EGLDisplay d, EGLSurface s) {
    (void)d; (void)s;
    if (!g_ctx || !ensure_target()) return 0;
    [EAGLContext setCurrentContext:g_ctx];
    glBindRenderbuffer(GL_RENDERBUFFER, g_rbo);
    if (getenv("DM_GLPROBE") && (++g_swapno == 1 || g_swapno == 100 || g_swapno == 600)) {
        // 读回画布中心 16x16：区分「游戏画出来是黑的」与「画了但没合成上屏」
        // Read back a 16x16 patch at the canvas centre: distinguishes "the game draws black" from "drawn but not composited on screen"
        GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
        GLint bound = -1; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &bound);
        GLubyte px[16 * 16 * 4] = {0}, px2[16 * 16 * 4] = {0};
        if (vp[2] > 32 && vp[3] > 32) glReadPixels(vp[2] / 2 - 8, vp[3] / 2 - 8, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, px);   // 当前绑定的 FBO | the currently bound FBO
        glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
        if (vp[2] > 32 && vp[3] > 32) glReadPixels(vp[2] / 2 - 8, vp[3] / 2 - 8, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, px2);  // 宿主 FBO（会被 present） | the host FBO (what gets presented)
        unsigned sum = 0, sum2 = 0; for (unsigned i = 0; i < sizeof px; i++) { sum += px[i]; sum2 += px2[i]; }
        LOG("[glprobe] swap#%lld 画布 %dx%d 视口 %dx%d 绑定 FBO=%d 均值 %u 宿主 FBO 均值 %u", g_swapno, (int)g_glview.bounds.size.width, (int)g_glview.bounds.size.height, vp[2], vp[3], bound, sum, sum2);
    }
    BOOL ok = [g_ctx presentRenderbuffer:GL_RENDERBUFFER];
    if (!ok) LOG("【红】[egl] presentRenderbuffer 失败");
    return ok ? 1 : 0;
}
HLE_FORCE("eglDestroySurface", "VA-11 iOS：销毁面 → 空操作", EGLBoolean, h_egl_DestroySurface, EGLDisplay d, EGLSurface s) { (void)d; (void)s; return 1; }

// ---- nv 驱动客户端：两条显存信息接口空操作（与 Mac 版一致；VA-11 的 GM runner 只在初始化时探一下） ----
// ---- nv driver client: the two video-memory info entry points are no-ops (as on Mac; VA-11's GM runner only probes them at init) ----
HLE_FORCE("_ZN2nv21GetGraphicsMemoryInfoEPNS_10MemoryInfoE", "VA-11 iOS：显存信息空", int32_t, h_nv_GetMemInfo, void *info) { (void)info; return 0; }
HLE_FORCE("_ZN2nv22DumpGraphicsMemoryInfoEv", "VA-11 iOS：不转储", void, h_nv_DumpMem, void) {}

// 导入解析：gl*/egl*/nv* → 宿主实现。gl* 直连系统 GLES（链接了 OpenGLES.framework，dlsym 能取到）；
// 只有 glBindFramebuffer 需要包装（默认缓冲 0 → 宿主 FBO）。
// Import resolution: gl*/egl*/nv* -> host implementations. gl* resolve straight to the system GLES (OpenGLES.framework
// is linked, so dlsym finds them); only glBindFramebuffer needs wrapping (default buffer 0 -> the host FBO).
void *hle_gl_sym(const char *name) {
    if (!strncmp(name, "egl", 3)) {
        void *p = dlsym(RTLD_DEFAULT, name);
        if (p && p != (void *)hle_gl_sym) return p;   // FORCE 表里的实现在装载时优先，这里只为兜底 | the FORCE implementations win at load time; this is only a fallback
        return NULL;
    }
    if (!strncmp(name, "gl", 2)) {
        if (!strcmp(name, "glBindFramebuffer")) return (void *)h_glBindFramebuffer;
        void *p = dlsym(RTLD_DEFAULT, name);
        if (!p) LOG("【红】gl 导入没有宿主实现：%s", name);
        return p;
    }
    return NULL;
}
