// VA-11 移植：GM runner 用到、D2R 没走到的其余服务面。
// 原则：纯函数给真实现（Inet* / 日历换算），离线服务给优雅缺省（成功或「不可用」），对话框类给空结果。
// VA-11 port: the remaining service surface the GM runner uses and D2R never reaches.
// Principle: pure functions get real implementations (Inet* / calendar conversion), offline services get
// graceful defaults (success or "unavailable"), and dialog-style services return empty results.
#include "hle.h"
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>

// nn::time::CalendarTime = s16 year; s8 month, day, hour, minute, second（8 字节）。
// ToPosixTimeFromUtc 真实 ABI：x0 = const CalendarTime&（输入），返回值即 posix 秒（guest 调用点
// main+0x1cd2d0 只取 x0）——先前误声明为 (out, cal) 两参：把日历指针当 out、垃圾 x1 当 cal 读崩。
// nn::time::CalendarTime = s16 year; s8 month, day, hour, minute, second (8 bytes).
// ToPosixTimeFromUtc's real ABI: x0 = const CalendarTime&, the return value IS the posix seconds
// (the guest call site main+0x1cd2d0 only takes x0) -- it was misdeclared as (out, cal) before.
typedef struct { int16_t year; int8_t month, day, hour, minute, second; } VaCal;
HLE_FORCE("_ZN2nn4time18ToPosixTimeFromUtcERKNS0_12CalendarTimeE", "VA-11：UTC 日历 → posix（宿主 timegm）", int64_t, h_time_ToPosixFromUtcM, const VaCal *cal) {
    if (!cal) return 0;
    struct tm tm = {0};
    tm.tm_year = cal->year - 1900; tm.tm_mon = cal->month - 1; tm.tm_mday = cal->day;
    tm.tm_hour = cal->hour; tm.tm_min = cal->minute; tm.tm_sec = cal->second;
    return (int64_t)timegm(&tm);
}

// ---- oe：显示分辨率 / 性能档（主机 720p；掌机语义） ----
// ---- oe: display resolution / performance level (docked 720p; handheld semantics) ----
HLE_FORCE("_ZN2nn2oe27GetDefaultDisplayResolutionEPiS1_", "VA-11：默认显示 1280x720", Result, h_oe_DefRes, int32_t *w, int32_t *h) { *w = 1280; *h = 720; return RES_OK; }
HLE_FORCE("_ZN2nn2oe27GetPerformanceConfigurationENS0_15PerformanceModeE", "VA-11：性能配置固定值", Result, h_oe_PerfCfg, int32_t *out, int32_t mode) { (void)mode; *out = 0x10000; return RES_OK; }
HLE_FORCE("_ZN2nn2oe21SetExpectedThemeColorENS0_14ThemeColorTypeE", "VA-11：主题色不接", void, h_oe_Theme, int32_t c) { (void)c; }
HLE_FORCE("_ZN2nn2oe29SetScreenShotImageOrientationENS_5album16ImageOrientationE", "VA-11：截图方向不接", void, h_oe_Orient, int32_t o) { (void)o; }

// ---- vi 变体 ----
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEii", "VA-11：带尺寸建图层 → 宿主静态图层", Result, h_vi_CreateLayer2, void **out, void *disp, int32_t w, int32_t h) {
    (void)disp; (void)w; (void)h; *out = (void *)0x4C415952; return RES_OK;   // 'RALY'
}
HLE_FORCE("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE", "VA-11：图层销毁空操作", Result, h_vi_DestroyLayer, void *layer) { (void)layer; return RES_OK; }

// ---- swkbd 缺的几条（ShowKeyboard 已有宿主接管） ----
HLE_FORCE("_ZN2nn5swkbd10MakePresetEPNS0_14KeyboardConfigENS0_6PresetE", "VA-11：键盘预设不接", void, h_sk_Preset, void *cfg, int32_t preset) { (void)cfg; (void)preset; }
HLE_FORCE("_ZN2nn5swkbd16SetGuideTextUtf8EPNS0_14KeyboardConfigEPKc", "VA-11：引导文本不设", void, h_sk_Guide, void *cfg, const char *t) { (void)cfg; (void)t; }
HLE_FORCE("_ZN2nn5swkbd17SetHeaderTextUtf8EPNS0_14KeyboardConfigEPKc", "VA-11：标题文本不设", void, h_sk_Header, void *cfg, const char *t) { (void)cfg; (void)t; }
HLE_FORCE("_ZN2nn5swkbd18SetInitialTextUtf8EPNS0_15ShowKeyboardArgEPKc", "VA-11：初始文本不设", void, h_sk_Init, void *arg, const char *t) { (void)arg; (void)t; }
HLE_FORCE("_ZN2nn5swkbd25GetRequiredWorkBufferSizeEb", "VA-11：键盘工作区 1 MiB", unsigned long, h_sk_Work, unsigned char inline_flag) { (void)inline_flag; return 1 << 20; }
HLE_FORCE("_ZN2nn5swkbd27GetRequiredStringBufferSizeEv", "VA-11：键盘字符串区 1 KiB", unsigned long, h_sk_Str, void) { return 1024; }

// ---- err 对话框：构造与设参空操作（ShowError 已有宿主接管） ----
HLE_FORCE("_ZN2nn3err19ApplicationErrorArgC1Ev", "VA-11：错误参数构造空操作", void, h_err_Ctor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3err19ApplicationErrorArg15SetLanguageCodeERKNS_8settings12LanguageCodeE", "VA-11：错误语言不设", void, h_err_Lang, void *self, const void *code) { (void)self; (void)code; }
HLE_FORCE("_ZN2nn3err19ApplicationErrorArg16SetDialogMessageEPKc", "VA-11：错误消息不设", void, h_err_Msg, void *self, const char *m) { (void)self; (void)m; }
HLE_FORCE("_ZN2nn3err19ApplicationErrorArg20SetFullScreenMessageEPKc", "VA-11：全屏消息不设", void, h_err_Full, void *self, const char *m) { (void)self; (void)m; }
HLE_FORCE("_ZN2nn3err19ApplicationErrorArg29SetApplicationErrorCodeNumberEj", "VA-11：错误码不设", void, h_err_Num, void *self, uint32_t n) { (void)self; (void)n; }

// ---- ro（NRO 动态模块）：VA-11 无扩展模块，全部优雅失败 ----
HLE_FORCE("_ZN2nn2ro10InitializeEv", "VA-11：ro 初始化空操作", Result, h_ro_Init, void) { return RES_OK; }
HLE_FORCE("_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi", "VA-11：无 NRO 可载", Result, h_ro_Load, void *m, void *buf, void *heap, unsigned long n, int use_nested) { (void)m; (void)buf; (void)heap; (void)n; (void)use_nested; return RES_FAIL; }
HLE_FORCE("_ZN2nn2ro12UnloadModuleEPNS0_6ModuleE", "VA-11：无 NRO 可卸", Result, h_ro_Unload, void *m) { (void)m; return RES_FAIL; }
HLE_FORCE("_ZN2nn2ro12LookupSymbolEPmPKc", "VA-11：仅应答 MountHost，其余失败", Result, h_ro_Lookup, uint64_t *out, const char *name) {
    if (name && !strcmp(name, "_ZN2nn2fs9MountHostEPKcS2_")) {
        void *va11_mount_host_fn(void);
        *out = (uint64_t)va11_mount_host_fn();
        LOG("ro::LookupSymbol %s → 宿主实现", name);
        return RES_OK;
    }
    (void)out;
    return RES_FAIL;
}
HLE_FORCE("_ZN2nn2ro13GetBufferSizeEPmPKv", "VA-11：NRO 大小未知", Result, h_ro_Size, unsigned long *out, const void *nro) { (void)out; (void)nro; return RES_FAIL; }
HLE_FORCE("_ZN2nn2ro18RegisterModuleInfoEPNS0_16RegistrationInfoEPKv", "VA-11：模块登记空操作", Result, h_ro_Reg, void *info, const void *nro) { (void)info; (void)nro; return RES_OK; }
HLE_FORCE("_ZN2nn2ro20UnregisterModuleInfoEPNS0_16RegistrationInfoE", "VA-11：模块注销空操作", Result, h_ro_Unreg, void *info) { (void)info; return RES_OK; }

// ---- nifm 网络状态：完全离线 ----
HLE_FORCE("_ZN2nn4nifm19SetLocalNetworkModeEb", "VA-11：网络模式不接（离线）", void, h_nifm_Local, unsigned char on) { (void)on; }
HLE_FORCE("_ZN2nn4nifm22GetCurrentIpConfigInfoEP7in_addrS2_S2_S2_S2_", "VA-11：无 IP 配置", int32_t, h_nifm_IpCfg, void *ip, void *mask, void *gw, void *dns1, void *dns2) { (void)(void*)ip; (void)mask; (void)gw; (void)dns1; (void)dns2; return 0; }
HLE_FORCE("_ZN2nn4nifm26GetCurrentPrimaryIpAddressEP7in_addr", "VA-11：无主 IP", int32_t, h_nifm_Ip, void *ip) { (void)ip; return 0; }
HLE_FORCE("_ZN2nn4nifm26HandleNetworkRequestResultEv", "VA-11：网络请求结果不接", void, h_nifm_ReqRes, void) {}
HLE_FORCE("_ZN2nn4nifm27SubmitNetworkRequestAndWaitEv", "VA-11：网络请求直接完成（离线判定交上层）", int32_t, h_nifm_Submit, void) { return 0; }

// ---- socket：VA-11 完全离线；纯函数给真实现，其余一律失败 ----
HLE_FORCE("_ZN2nn6socket9InetHtonlEj", "VA-11：htonl 直连宿主", uint32_t, h_so_Htonl, uint32_t v) { return htonl(v); }
HLE_FORCE("_ZN2nn6socket9InetHtonsEt", "VA-11：htons 直连宿主", uint16_t, h_so_Htons, uint16_t v) { return htons(v); }
HLE_FORCE("_ZN2nn6socket9InetNtohsEt", "VA-11：ntohs 直连宿主", uint16_t, h_so_Ntohs, uint16_t v) { return ntohs(v); }
HLE_FORCE("_ZN2nn6socket8InetNtoaE7in_addr", "VA-11：inet_ntoa 直连宿主（返回静态串）", const char *, h_so_Ntoa, uint32_t in) {
    struct in_addr a = { .s_addr = in }; return inet_ntoa(a);
}
HLE_FORCE("_ZN2nn6socket8InetNtopEiPKvPcj", "VA-11：inet_ntop 直连宿主", const char *, h_so_Ntop, int af, const void *src, char *dst, int32_t n) { return inet_ntop(af, src, dst, (socklen_t)n); }
HLE_FORCE("_ZN2nn6socket8InetPtonEiPKcPv", "VA-11：inet_pton 直连宿主", int32_t, h_so_Pton, int af, const char *src, void *dst) { return (int32_t)inet_pton(af, src, dst); }
HLE_FORCE("_ZN2nn6socket6SocketEiii", "VA-11：离线，不建套接字", int32_t, h_so_Socket, int32_t f, int32_t t, int32_t p) { (void)f; (void)t; (void)p; return -1; }
HLE_FORCE("_ZN2nn6socket4BindEiPK8sockaddrj", "VA-11：离线", int32_t, h_so_Bind, int32_t s, const void *a, uint32_t l) { (void)s; (void)a; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket7ConnectEiPK8sockaddrj", "VA-11：离线", int32_t, h_so_Connect, int32_t s, const void *a, uint32_t l) { (void)s; (void)a; (void)l; return -1; }

HLE_FORCE("_ZN2nn6socket6AcceptEiP8sockaddrPj", "VA-11：离线", int32_t, h_so_Accept, int32_t s, void *a, uint32_t *l) { (void)s; (void)a; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket4RecvEiPvmi", "VA-11：离线", int32_t, h_so_Recv, int32_t s, void *b, unsigned long n, int32_t fl) { (void)s; (void)b; (void)n; (void)fl; return -1; }
HLE_FORCE("_ZN2nn6socket8RecvFromEiPvmiP8sockaddrPj", "VA-11：离线", int32_t, h_so_RecvFrom, int32_t s, void *b, unsigned long n, int32_t fl, void *a, uint32_t *l) { (void)s; (void)b; (void)n; (void)fl; (void)a; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket4SendEiPKvmi", "VA-11：离线", int32_t, h_so_Send, int32_t s, const void *b, unsigned long n, int32_t fl) { (void)s; (void)b; (void)n; (void)fl; return -1; }
HLE_FORCE("_ZN2nn6socket6SendToEiPKvmiPK8sockaddrj", "VA-11：离线", int32_t, h_so_SendTo, int32_t s, const void *b, unsigned long n, int32_t fl, const void *a, uint32_t l) { (void)s; (void)b; (void)n; (void)fl; (void)a; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket8ShutdownEii", "VA-11：离线", int32_t, h_so_Shutdown, int32_t s, int32_t how) { (void)s; (void)how; return 0; }
HLE_FORCE("_ZN2nn6socket5FcntlEiiz", "VA-11：离线", int32_t, h_so_Fcntl, int32_t s, int32_t cmd, int64_t a) { (void)s; (void)cmd; (void)a; return -1; }
HLE_FORCE("_ZN2nn6socket5IoctlEijPvm", "VA-11：离线", int32_t, h_so_Ioctl, int32_t s, uint32_t cmd, void *arg, unsigned long n) { (void)s; (void)cmd; (void)arg; (void)n; return -1; }
HLE_FORCE("_ZN2nn6socket6SelectEiP6fd_setS2_S2_P7timeval", "VA-11：离线", int32_t, h_so_Select, int32_t n, void *r, void *w, void *e, void *tv) { (void)n; (void)r; (void)w; (void)e; (void)tv; return 0; }
HLE_FORCE("_ZN2nn6socket10GetSockOptEiiiPvPj", "VA-11：离线", int32_t, h_so_GetOpt, int32_t s, int32_t lv, int32_t op, void *v, uint32_t *l) { (void)s; (void)lv; (void)op; (void)v; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket10SetSockOptEiiiPKvj", "VA-11：离线", int32_t, h_so_SetOpt, int32_t s, int32_t lv, int32_t op, const void *v, uint32_t l) { (void)s; (void)lv; (void)op; (void)v; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket11GetPeerNameEiP8sockaddrPj", "VA-11：离线", int32_t, h_so_Peer, int32_t s, void *a, uint32_t *l) { (void)s; (void)a; (void)l; return -1; }
HLE_FORCE("_ZN2nn6socket11GetAddrInfoEPKcS2_PK8addrinfoPPS3_", "VA-11：离线，无解析", int32_t, h_so_GetAI, const char *h, const char *srv, const void *hint, void **out) { (void)h; (void)srv; (void)hint; (void)out; return -1; }

// ---- ssl：离线 ----
HLE_FORCE("_ZN2nn3ssl7Context15ImportServerPkiEPmPKcjNS0_17CertificateFormatE", "VA-11：离线", int32_t, h_ssl_Import, void *ctx, uint64_t *out, const void *data, uint32_t n, int32_t fmt) { (void)ctx; (void)out; (void)data; (void)n; (void)fmt; return -1; }
HLE_FORCE("_ZN2nn3ssl10Connection19SetServerCertBufferEPcj", "VA-11：离线", int32_t, h_ssl_Cert, void *c, const void *b, uint32_t n) { (void)c; (void)b; (void)n; return -1; }
HLE_FORCE("_ZN2nn3ssl10Connection19GetVerifyCertErrorsEPNS_6ResultEPjS4_j", "VA-11：离线", int32_t, h_ssl_Ver, void *c, void *r, uint32_t *a, uint32_t *b, uint32_t n) { (void)c; (void)r; (void)a; (void)b; (void)n; return -1; }

// ---- irsensor（红外相机）：VA-11 不用，全部空 ----
HLE_FORCE("_ZN2nn8irsensor10InitializeERKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_Init, const void *h) { (void)h; return RES_OK; }
HLE_FORCE("_ZN2nn8irsensor17GetIrCameraHandleERKj", "VA-11：红外句柄零", Result, h_ir_Handle, uint32_t *out) { *out = 0; return RES_OK; }
HLE_FORCE("_ZN2nn8irsensor15RunHandAnalysisERKNS0_14IrCameraHandleERKNS0_18HandAnalysisConfigE", "VA-11：红外不接", Result, h_ir_Hand, const void *h, const void *c) { (void)h; (void)c; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor18RunMomentProcessorERKNS0_14IrCameraHandleERKNS0_21MomentProcessorConfigE", "VA-11：红外不接", Result, h_ir_Moment, const void *h, const void *c) { (void)h; (void)c; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor22RunClusteringProcessorERKNS0_14IrCameraHandleERKNS0_25ClusteringProcessorConfigE", "VA-11：红外不接", Result, h_ir_Cluster, const void *h, const void *c) { (void)h; (void)c; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor23StopImageProcessorAsyncERKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_Stop, const void *h) { (void)h; return RES_OK; }
HLE_FORCE("_ZN2nn8irsensor23GetMomentProcessorStateEPNS0_20MomentProcessorStateERKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_MState, void *s, const void *h) { (void)s; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor25GetHandAnalysisImageStateEPNS0_22HandAnalysisImageStateEPiilRKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_HState, void *s, int32_t *v, int32_t a, long b, const void *h) { (void)s; (void)v; (void)a; (void)b; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor25RunImageTransferProcessorERKNS0_14IrCameraHandleERKNS0_30ImageTransferProcessorExConfigEPvm", "VA-11：红外不接", Result, h_ir_Transfer, const void *h, const void *c, void *b, unsigned long n) { (void)h; (void)c; (void)b; (void)n; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor27GetClusteringProcessorStateEPNS0_24ClusteringProcessorStateERKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_CState, void *s, const void *h) { (void)s; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor30GetHandAnalysisSilhouetteStateEPNS0_27HandAnalysisSilhouetteStateEPiilRKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_Sil, void *s, int32_t *v, int32_t a, long b, const void *h) { (void)s; (void)v; (void)a; (void)b; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor30GetImageTransferProcessorStateEPNS0_27ImageTransferProcessorStateEPvmRKNS0_14IrCameraHandleE", "VA-11：红外不接", Result, h_ir_TState, void *s, void *b, unsigned long n, const void *h) { (void)s; (void)b; (void)n; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn8irsensor31GetMomentProcessorDefaultConfigEPNS0_21MomentProcessorConfigE", "VA-11：红外不接", void, h_ir_MDef, void *c) { (void)c; }
HLE_FORCE("_ZN2nn8irsensor35GetClusteringProcessorDefaultConfigEPNS0_25ClusteringProcessorConfigE", "VA-11：红外不接", void, h_ir_CDef, void *c) { (void)c; }
HLE_FORCE("_ZN2nn8irsensor38GetImageTransferProcessorDefaultConfigEPNS0_30ImageTransferProcessorExConfigE", "VA-11：红外不接", void, h_ir_TDef, void *c) { (void)c; }

// ---- ec / friends ----
HLE_FORCE("_ZN2nn2ec30ShowShopApplicationInformationENS_13ApplicationIdE", "VA-11：商店不接", void, h_ec_Shop, uint64_t appid) { (void)appid; }
HLE_FORCE("_ZN2nn7friends12AsyncContext7HasDoneEPb", "VA-11：好友异步恒完成", void, h_fr_Done, void *self, unsigned char *done) { (void)self; if (done) *done = 1; }

// ---- diag 日志直通：YoYo runner 自己的启动日志经 nn::diag，接管后能看见它的退出原因 ----
// ---- diag log passthrough: the YoYo runner's own boot log goes through nn::diag; taking it over
// lets us see why it exits. ----
#import <stdarg.h>
HLE_FORCE("_ZN2nn4diag6detail7LogImplERKNS0_11LogMetaDataEPKcz", "VA-11：客体日志 → 宿主 stdout", void, h_va11_LogImpl, void *meta, const char *fmt, ...) {
    (void)meta;
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}
HLE_FORCE("_ZN2nn4diag6detail18OnAssertionFailureENS0_13AssertionTypeEPKcS4_S4_i", "VA-11：断言失败打印后继续（原版会 Break）", int32_t, h_va11_AssertFail, int32_t type, const char *file, const char *fn, int line) {
    fprintf(stderr, "[guest assert] %s:%s:%d (type %d)\n", file ? file : "?", fn ? fn : "?", line, type);
    return 0;
}

// ---- nn::os 互斥：音频拆卸竞态加固 ----
// FMOD 在主循环起点拆音频：FinalizeMutex → Free(holder) → holder[0] 置 NULL。真机上混音线程
// 这时已被停掉；宿主上它还在跑，会拿 NULL 调 LockMutex（sdk+0xac5e8 读 [NULL+1] 即崩）。
// 空互斥视作「对象已在拆卸」直接返回；非空转 sdk 真实实现（符号表取址，不经 FORCE 改写的 GOT）。
// ---- nn::os mutex: hardening against the audio-teardown race ----
// At main-loop start FMOD tears audio down: FinalizeMutex -> Free(holder) -> holder[0] = NULL. On
// real hardware the mixer thread has been stopped by then; on the host it is still running and calls
// LockMutex with NULL (sdk+0xac5e8 reads [NULL+1] and dies). Treat a NULL mutex as "object already
// being torn down" and return; anything else goes to the real sdk implementation (address from the
// symbol table, bypassing the FORCE-rewritten GOT).
static void (*g_va11_real_lock)(void *);
static void (*g_va11_real_unlock)(void *);
static int g_va11_nullmutex_warned;
static void va11_mutex_warn(const char *what) {
    if (g_va11_nullmutex_warned++ == 0) LOG("[va11] %s(NULL)：互斥已在拆卸中，按空操作处理（后续不再重复记录）", what);
}
HLE_FORCE("_ZN2nn2os9LockMutexEPNS0_9MutexTypeE", "VA-11：拆卸竞态——空互斥直通，非空转真实实现", void, h_va11_LockMutex, void *m) {
    if (!m) { va11_mutex_warn("LockMutex"); return; }
    if (!g_va11_real_lock) g_va11_real_lock = (void (*)(void *))guest_sym("_ZN2nn2os9LockMutexEPNS0_9MutexTypeE");
    g_va11_real_lock(m);
}
HLE_FORCE("_ZN2nn2os11UnlockMutexEPNS0_9MutexTypeE", "VA-11：拆卸竞态——空互斥直通，非空转真实实现", void, h_va11_UnlockMutex, void *m) {
    if (!m) { va11_mutex_warn("UnlockMutex"); return; }
    if (!g_va11_real_unlock) g_va11_real_unlock = (void (*)(void *))guest_sym("_ZN2nn2os11UnlockMutexEPNS0_9MutexTypeE");
    g_va11_real_unlock(m);
}
HLE_FORCE("_ZN2nn2os12TryLockMutexEPNS0_9MutexTypeE", "VA-11：拆卸竞态——空互斥按未得上锁，非空转真实实现", unsigned char, h_va11_TryLockMutex, void *m) {
    if (!m) { va11_mutex_warn("TryLockMutex"); return 0; }
    static unsigned char (*real)(void *);
    if (!real) real = (unsigned char (*)(void *))guest_sym("_ZN2nn2os12TryLockMutexEPNS0_9MutexTypeE");
    return real(m);
}

// ---- nn::diag::detail::AbortImpl：SDK 断言中止——情报口 + 调用方分流 ----
// show_message 链(对话框已补 RET)放行让 GML 继续;其它真断言打印后退出。
// ---- nn::diag::detail::AbortImpl: information tap + caller triage ----
// The show_message chain (dialog RET-patched) is let through so GML continues; other real
// assertions print and exit.
HLE_FORCE("_ZN2nn4diag6detail9AbortImplEPKcS3_S3_i", "VA-11：SDK 断言中止打印情报", Result, h_diag_AbortImpl, const char *a, const char *b, const char *c, int line) {
    LOG("diag::AbortImpl: a=%s b=%s c=%s line=%d", a ? a : "(null)", b ? b : "(null)", c ? c : "(null)", line);
    int dm_in_show_message(void *);
    if (dm_in_show_message(__builtin_frame_address(0))) {
        LOG("diag::AbortImpl:show_message 链——对话框已补 RET,放行继续");
        return RES_OK;   // 调用方 sdk+0xc0764 已补 RET,x0 当 Result 用 | caller is RET-patched; x0 doubles as the Result
    }
    _exit(43);
    return RES_OK;
}

// 调试触点脚本入口（DM_TAP）：构造期启动，主机起来就跑（桌面 headless 与 iOS 都可用）。
// Debug tap-script entry (DM_TAP): started from a constructor so it runs as soon as the host is up (headless desktop and iOS).
__attribute__((constructor)) static void dm_tap_ctor(void) { void dm_tap_start(void); dm_tap_start(); }
