// Va11IOS：VA-11 HALL-A 的 iOS 外壳 + 宿主前端（front.h 的 iOS 实现）。
// 壳负责：UIKit 窗口与 EAGL 出图视图、把宿主日志落到 Documents/boot.txt、给宿主备好存档/临时目录与产品目录参数；
// 前端负责：跑客体（front_run）、给 EGL 垫片交出图图层（front_metal_layer）、游戏输出分辨率（front_game_res）、
// 触摸（dm_touch_set）、软键盘输入框（front_text_input）、存档写失败提示（front_save_failed）、生命周期。
// 图形：GM runner 走 EGL + GLES，宿主用 EAGL 直连（见 dm/host/hle_egl_ios.m），不需要 Metal 翻译层。
// Va11IOS: the iOS shell + host front end (the iOS implementation of front.h) for VA-11 HALL-A.
// The shell: UIKit window and EAGL view, host log to Documents/boot.txt, save/temporary directories and product-directory
// arguments for the host. The front end: run the guest (front_run), give the EGL shim its output layer
// (front_metal_layer), the game output resolution (front_game_res), touch (dm_touch_set), the soft-keyboard input box
// (front_text_input), the save-write-failure prompt (front_save_failed), and the lifecycle.
// Graphics: the GM runner uses EGL + GLES and the host hooks EGL straight to EAGL (see dm/host/hle_egl_ios.m);
// no Metal translation layer is involved.
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>
#import <crt_externs.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "front.h"
#include "dm.h"
#include "hle.h"
#include "dm_input.h"

// 游戏输出分辨率：GM runner 固定按 1280x720 建视口（nn::oe 的默认显示分辨率，Mac 上 glprobe 实测 vp=1280x720），
// EAGL 画布就跟它一样大——画布与视口一致，画面才铺满；再由 CA 等比缩到屏幕上（16:9 以外留黑边）。
// Game output resolution: the GM runner always builds a 1280x720 viewport (nn::oe's default display resolution; measured
// as vp=1280x720 by the Mac glprobe), so the EAGL canvas is that exact size -- canvas and viewport must match for the
// picture to fill it; Core Animation then scales it uniformly onto the screen (black bars outside 16:9).
static const int kGameW = 1280, kGameH = 720;

int dm_main(int argc, char **argv);   // dm/host/main.c 以 -Dmain=dm_main 编入 | dm/host/main.c is compiled in with -Dmain=dm_main
void hle_egl_set_view(void *view);    // hle_egl_ios.m

// ---------- 全局 ----------
static UIWindow *g_win;
static UIView *g_root;                // 黑底容器，铺满屏幕 | black container filling the screen
static UIView *g_view;
_Atomic uint64_t g_front_touch_ns;   // 前端最近一次收到真实的 UI 触摸的时刻（窗口级兜底手势用它判断是否重复） | time of the last real UI touch (the window-level fallback gesture uses it to avoid double handling)                // EAGL 视图：bounds = 游戏分辨率、contentsScale = 1 | EAGL view: bounds = game resolution, contentsScale = 1
static CAEAGLLayer *g_layer;
static char *g_arg[8];
static int g_argc;
static int g_boot_started;
static UIView *g_touch_hud;   // 触屏虚拟键容器 | virtual-button container

// 触屏虚拟键：屏幕上叠几个半透明按钮，按下/抬起直接合成手柄按键（dm_input_set）。
// VA-11 的「按 A 确认 / 按 A 继续对话」这类提示没有鼠标等价物，点选玩法又需要鼠标，
// 所以两条输入面并存：点画面 = 鼠标（hle_touch.c 的鼠标面），右下角按钮 = 手柄。
// On-screen virtual buttons: a few translucent buttons overlay the screen and synthesize gamepad buttons on press /
// release (dm_input_set). Prompts such as "press A to confirm / advance" have no mouse equivalent while point-and-select
// needs the mouse, so both surfaces coexist: tapping the picture = mouse (the mouse surface in hle_touch.c), the buttons
// in the bottom-right corner = gamepad.
static uint64_t g_touch_btn;
static void pad_publish(void) { dm_input_set(g_touch_btn, 0, 0, 0, 0); }
static void pad_press(uint64_t mask) { g_touch_btn |= mask; pad_publish(); LOG("[pad] 按下 %#llx", (unsigned long long)mask); }
static void pad_release(uint64_t mask) { g_touch_btn &= ~mask; pad_publish(); }

// dm_gamepad.m（宿主共用的手柄模块）引用的 D2R 界面导航入口；VA-11 没有这层界面，给空实现（返回 0 = 不在导航页）。
// The D2R UI-navigation entry referenced by dm_gamepad.m (the gamepad module shared by the host); VA-11 has no such UI
// layer, so provide an empty implementation (returns 0 = not on a navigation page).
int dm_front_navigation(void) { return 0; }

// ---------- front.h：前端接口 ----------
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
uint64_t front_game_res(int docked) { (void)docked; return (uint64_t)kGameH << 32 | kGameW; }

// 客体线程：信号备用栈（崩溃打印要用）+ 解除 UIKit 主线程带来的信号屏蔽（诊断信号 SIGUSR2 / SIGALRM 否则收不到）。
// 壳先把 dm_main 放到 64 MiB 栈的后台线程上，所以这里直接跑 guest()，不再起线程。
// Guest thread: alternate signal stack (needed by the crash printout) + unblock the signal mask inherited from the
// UIKit main thread (otherwise the diagnostic signals SIGUSR2 / SIGALRM never arrive). The shell already puts dm_main on
// a 64 MiB-stack background thread, so guest() runs here directly instead of spawning another thread.
void front_run(void (*guest)(void)) {
    static char alt[65536];
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    sigset_t all; sigfillset(&all); pthread_sigmask(SIG_UNBLOCK, &all, NULL);
    guest();
}

// 软键盘输入框（front.h）：主线程弹 UIAlertController + 文本框，客体线程阻塞到确定 / 取消。
// 无窗口时返回 -1。VA-11 正常流程不弹（GM runner 没有文本输入），留给命名等边缘路径。
// Soft-keyboard input box (front.h): the main thread presents a UIAlertController + text field and the guest thread
// blocks until OK / Cancel. Returns -1 with no window. VA-11's normal flow never shows it (the GM runner has no text
// input); it is kept for edge paths such as naming.
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)guide; (void)max_chars;
    if (!g_view || !out || out_cap <= 0) return -1;
    __block int rc = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@(title ?: "") message:@(sub ?: "") preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = @(initial ?: ""); }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            NSString *t = ac.textFields.firstObject.text ?: @"";
            snprintf(out, (size_t)out_cap, "%s", t.UTF8String);
            rc = 1; dispatch_semaphore_signal(sem);
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { (void)a; rc = 0; dispatch_semaphore_signal(sem); }]];
        [g_win.rootViewController presentViewController:ac animated:YES completion:nil];
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return rc;
}

// 存档写失败（front.h）：主线程弹系统提示，不阻塞游戏线程。
// Save write failed (front.h): show a system prompt on the main thread; do not block the game thread.
void front_save_failed(int err) {
    LOG("存档写失败 err=%d（%s），提示玩家", err, strerror(err));
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"存储空间不足" message:@"进度未保存。请清理空间后重试。" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [g_win.rootViewController presentViewController:ac animated:YES completion:nil];
    });
}

// ---------- EAGL 视图：多点触摸 → dm_touch_set ----------
static void tap_a_pulse(void);   // 点按补 A（视图与测试脚本共用）| tap-to-A, shared by the view and the test hooks
// 带坐标版本：帧同步鼠标点击要用真实落点（菜单项不在屏幕中心）；无坐标版本按屏幕中心补。
// Coordinate-carrying variant: the frame-synced mouse click must use the real hit point (menu items are not at the
// screen centre); the no-argument variant pulses at the centre.
static void tap_a_pulse_at(float nx, float ny);
static void front_window_tap(float nx, float ny);   // 窗口级兜底注入（手势与 wintap 测试步共用） | window-level fallback injection (shared by the gesture and the wintap test step)
static uint64_t pad_mask_of(const char *nm);   // 键名→掩码（DM_TEST_* 钩子用）| key name -> mask (used by the DM_TEST_* hooks)

@interface Va11GLView : UIView
@end
@implementation Va11GLView
+ (Class)layerClass { return [CAEAGLLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.multipleTouchEnabled = YES; self.opaque = YES; self.backgroundColor = UIColor.blackColor; }
    return self;
}
// 触点集合一有变化整组推一次：id = 手指槽号（按下取最小空槽，抬起前不变），x/y = 画面归一化坐标（左上原点）。
// The whole touch set is pushed whenever it changes: id = finger slot (lowest free slot on down, unchanged until up),
// x/y = normalised coordinates on the picture (origin at top left).
- (void)pushTouches:(NSSet<UITouch *> *)touches {
    // 只收「还按着」的手指：event.allTouches 在抬手事件里仍然包含那根已结束的手指，
    // 原来把所有 allTouches 都当按下推，导致**抬手永远不会被推成 n=0**——游戏看到一根一直按着的手指，
    // 后续点按全部被当成「已经按着」，点按补 A 也不会触发（真机触摸没反应的真因）。
    // Only collect fingers that are still down: on a lift event event.allTouches still contains the ended touch, so the
    // old code always pushed n>=1 and the release (n=0) was never delivered -- the game saw one permanently held finger,
    // every later tap looked like "already held", and the tap-to-A pulse never fired (the real cause of dead touch on device).
    UITouch *all[16]; int n = 0;
    for (UITouch *t in touches) {
        if (n >= 16) break;
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
        all[n++] = t;
    }
    // 稳定排序：按触摸对象地址排，保证同一组触点每次推送的槽号顺序一致（游戏按 id 跟踪手指）
    // Stable order: sort by the touch object's address so the same set always pushes slots in the same order (the game tracks fingers by id)
    for (int i = 1; i < n; i++) for (int j = i; j > 0 && (uintptr_t)all[j] < (uintptr_t)all[j - 1]; j--) { UITouch *x = all[j]; all[j] = all[j - 1]; all[j - 1] = x; }
    dm_touch ts[16];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    for (int i = 0; i < n; i++) {
        CGPoint p = [all[i] locationInView:self];
        float nx = w > 0 ? (float)(p.x / w) : 0, ny = h > 0 ? (float)(p.y / h) : 0;
        ts[i].id = (uint32_t)i;
        ts[i].x = nx < 0 ? 0 : nx > 0.999f ? 0.999f : nx;
        ts[i].y = ny < 0 ? 0 : ny > 0.999f ? 0.999f : ny;
    }
    dm_touch_set(n ? ts : NULL, n);
    // 诊断：记录前端收到的触点（首次 6 次 + 每 60 次一行），用来判断「真机触摸有没有到 App」。
    // Diagnostic: log touches received by the front end (first 6 + one per 60) to tell whether a real touch reaches the app at all.
    extern _Atomic uint64_t g_front_touch_ns; atomic_store(&g_front_touch_ns, now_ns());
    { static int cnt; int c = ++cnt; if (c <= 6 || (c % 60) == 0) LOG("[front] 触摸推 %d 点 #0=(%.3f,%.3f) 视图=%.0fx%.0f 第 %d 次", n, n ? ts[0].x : -1.0f, n ? ts[0].y : -1.0f, (double)w, (double)h, c); }
    // 触屏优先：按下 = 鼠标点 + 内部补两拍 A（不等抬手、也不看按住时长——鼠标按住超过 0.35 s 也算点按）。
    // Touch-first: a press = mouse click + two internal A pulses (no release/hold-duration gate: holding the mouse for
    // longer than 0.35 s still counts as a tap).
    static int g_was_down; static float g_last_nx = 0.5f, g_last_ny = 0.5f;
    if (n > 0) { g_last_nx = ts[0].x; g_last_ny = ts[0].y; }
    if (n > 0 && !g_was_down) g_was_down = 1;
    else if (n == 0 && g_was_down) { g_was_down = 0; LOG("[front] 点按抬手 → 补 A/点击 (%.3f,%.3f)", g_last_nx, g_last_ny); tap_a_pulse_at(g_last_nx, g_last_ny); }   // 用真实落点补点击/A | pulse the click/A at the real hit point
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; [self pushTouches:event.allTouches]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; [self pushTouches:event.allTouches]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; [self pushTouches:event.allTouches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)touches; [self pushTouches:event.allTouches]; }
@end

// ---------- 触屏虚拟键容器：只在按钮自己的矩形里吃事件,空白处穿透到 GL 视图 ----------
// 之前容器是普通 UIView(默认 userInteractionEnabled=YES)盖满全屏,把 GL 视图的触摸全部吞掉
// ——「触控完全不可用」的根因。这里覆写 hitTest:点落在任一子按钮上才命中,否则返回 nil 放行。
// ---------- Touch HUD container: takes events only inside its buttons; empty areas pass through ----------
// The container used to be a plain full-screen UIView (userInteractionEnabled defaults to YES) that swallowed
// every touch before the GL view saw it -- the root cause of "touch completely dead". hitTest returns a hit
// only when the point falls on a child button; otherwise nil so the touch falls through.
@interface TouchHudBox : UIView
@end
@implementation TouchHudBox
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        CGPoint ps = [self convertPoint:p toView:sub];
        if (sub.userInteractionEnabled && !sub.hidden && sub.alpha > 0.01 && [sub pointInside:ps withEvent:event])
            return [super hitTest:p withEvent:event];   // 深层命中交给 UIKit(返回按钮本身) | let UIKit resolve the deepest hit (the button)
    }
    return nil;   // 空白处穿透 | fall through on empty areas
}
@end

// ---------- 启动准备（main() 里、UIApplicationMain 之前） ----------
// 目录 / 环境变量 / cwd / 产品目录参数：宿主装载读这些。DM_SAVE 等已由外部设置时不覆盖（冒烟用 SIMCTL_CHILD_DM_* 指测试目录）。
// Directories / environment variables / cwd / product-directory arguments: host loading reads these. Existing DM_SAVE
// and friends are not overridden (the smoke test points them at a test directory with SIMCTL_CHILD_DM_*).
static void set_default_language(void);

static void boot_env(void) {
    set_default_language();   // 汉化补丁的中文在英文槽：默认按 en-US 走 | the CN patch keeps Chinese in the English slot: default to en-US
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = docs.firstObject;
    NSString *save = [doc stringByAppendingPathComponent:@"save"];
    NSString *temp = [doc stringByAppendingPathComponent:@"temp"];
    [fm createDirectoryAtPath:save withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("DM_SAVE", save.fileSystemRepresentation, 0);
    setenv("DM_TEMP", temp.fileSystemRepresentation, 0);
    setenv("DM_AUDIO", "1", 0);                       // iOS 产品缺省真出声（hle_audio.c） | iOS product plays real sound by default (hle_audio.c)
    // 强制接管清单是 d2r 的并集，VA-11 只用到其中一部分：宽容模式只警告不中止（Mac 侧同样是 DM_HLE_TOLERANT=1 才能起）。
    // The forced-takeover list is the d2r superset and VA-11 references only part of it: tolerant mode warns instead of
    // aborting (the Mac side likewise only boots with DM_HLE_TOLERANT=1).
    setenv("DM_HLE_TOLERANT", "1", 0);
    // 日志：stdout/stderr → Documents/boot.txt（产品；冒烟从这里拉结果）。DM_LOG_CONSOLE=1 时不改向，留给 simctl --console。
    // Log: stdout/stderr -> Documents/boot.txt (product; the smoke test pulls its result from there). With DM_LOG_CONSOLE=1 the
    // redirection is skipped, leaving the output for simctl --console.
    if (!getenv("DM_LOG_CONSOLE")) {
        NSString *logp = [doc stringByAppendingPathComponent:@"boot.txt"];
        freopen(logp.fileSystemRepresentation, "w", stderr);
        dup2(fileno(stderr), fileno(stdout));
    }
    setvbuf(stderr, NULL, _IOLBF, 0);
    // 工作目录 = Documents：环境变量里的相对路径都落在这里（容器路径启动前不可知）
    // Working directory = Documents: relative paths in environment variables land here (the container path is not known before launch)
    if (chdir(doc.fileSystemRepresentation)) fprintf(stderr, "[boot] 【红】chdir Documents 失败 %s\n", strerror(errno));
    // 产品目录 = App 内的 dm/（装载表 / 门表）；模块名按 Mac 宿主的装载顺序
    // Product directory = dm/ inside the App (load tables / gate tables); module names follow the Mac host's load order
    NSString *res = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    g_arg[0] = "dmhost"; g_arg[1] = strdup(res.fileSystemRepresentation);
    g_arg[2] = "main"; g_arg[3] = "sdk"; g_arg[4] = "subsdk0"; g_arg[5] = "subsdk1";
    g_argc = 6;
    fprintf(stderr, "[boot] 产品目录 %s\n[boot] 存档目录 %s\n", g_arg[1], getenv("DM_SAVE"));
}

// 载荷自检：四个模块的内嵌段在不在（装载器会再核一遍；这里先给一行可读结论）。
// Payload self-check: are the four modules' embedded sections present (the loader checks again; this gives one readable line first).
static void payload_check(void) {
    static const char *MODS[] = {"main", "sdk", "subsdk0", "subsdk1"};
    // 用与装载器一致的宿主映像解析：LiveContainer 等侧载器在宿主进程内加载时，
    // _NSGetMachExecuteHeader 指向宿主 App，内嵌段会被误报全缺失。
    // Use the same host-image resolution as the loader: a sideloader (LiveContainer) loads the app inside its own
    // process, so _NSGetMachExecuteHeader points at the host app and every embedded section looked missing.
    const struct mach_header_64 *dm_host_image(void);
    const struct mach_header *mh = (const struct mach_header *)dm_host_image();
    int bad = 0;
    for (unsigned i = 0; i < sizeof MODS / sizeof MODS[0]; i++) {
        const char *m = MODS[i];
        char s0[32], sw[32], s1[32];
        snprintf(s0, sizeof s0, "__dm%sx0", m); snprintf(sw, sizeof sw, "__DM%sW", m); snprintf(s1, sizeof s1, "__dm%sx1", m);
        unsigned long z0 = 0, zw = 0, z1 = 0;
        uint8_t *p0 = getsectiondata(mh, "__TEXT", s0, &z0);
        uint8_t *pw = getsectiondata(mh, sw, "__img", &zw);
        uint8_t *p1 = getsectiondata(mh, "__TEXT", s1, &z1);
        int ok = p0 && pw && p1 && z0 && zw && z1;
        if (!ok) bad = 1;
        fprintf(stderr, "[boot] 内嵌段 %s: x0=%lu W=%lu x1=%lu %s\n", m, z0, zw, z1, ok ? "OK" : "X 缺");
    }
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *save = [docs.firstObject stringByAppendingPathComponent:@"save"];
    NSString *gw = [save stringByAppendingPathComponent:@"game.win"];
    BOOL hasGame = [[NSFileManager defaultManager] fileExistsAtPath:gw];
    fprintf(stderr, "[boot] game.win: %s（%s）\n", hasGame ? "在" : "缺", gw.fileSystemRepresentation);
    fprintf(stderr, "[boot] %s\n", (bad || !hasGame) ? "SHELL-RED（载荷/游戏数据不全，见上）" : "SHELL-OK（载荷与游戏数据齐）");
}

// 诊断/验收：DM_TEST_TAP=秒:x,y[;秒:x,y…]（归一化坐标，左上原点）在客起来后按脚本点屏幕——
// 走与真手指同一条路（dm_touch_set → 宿主触屏状态 → 游戏经 nn::hid 读），配合 DM_TOUCH_LOG=1 可核对注入到位。
// Diagnostic / acceptance: DM_TEST_TAP=<seconds>:<x>,<y>[;...] (normalised, origin top left) taps the screen on a schedule
// once the guest is up -- through the same path as a real finger (dm_touch_set -> host touch state -> the game reads it
// through nn::hid); with DM_TOUCH_LOG=1 the injection can be verified.
static void tap_schedule(void) {
    const char *e = getenv("DM_TEST_TAP");
    if (!e || !*e) return;
    LOG("[test] 触摸脚本 %s", e);
    for (const char *q = e; q && *q; q = strchr(q, ';') ? strchr(q, ';') + 1 : NULL) {
        double at = atof(q); const char *c = strchr(q, ':'); float x = 0, y = 0;
        if (!c || sscanf(c + 1, "%f,%f", &x, &y) != 2) continue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dm_touch t = {0, x, y};
            LOG("[test] 第 %.1f 秒按下 (%.3f,%.3f)", at, x, y);
            dm_touch_set(&t, 1);
            usleep(120000);
            LOG("[test] 第 %.1f 秒抬起", at);
            dm_touch_set(NULL, 0);
        });
    }
}

// 默认语言：这份汉化补丁把中文放进游戏的「英文」语言槽（脚本目录 scripts/chn 之外，UI 文案也按英文槽替换）。
// 实测：宿主返回 zh-Hans 时游戏落到日文；返回 en-US 时整片对白/提示都是中文。因此缺省给 en-US。
// Default language: this CN patch stores the Chinese text in the game's *English* language slot (UI strings included).
// Observed: with zh-Hans the game falls back to Japanese; with en-US the whole dialogue/prompt is Chinese. Default to en-US.
static void set_default_language(void) {
    if (!getenv("DM_LANG")) setenv("DM_LANG", "en-US", 1);
    // 掌机模式（真机 NS 掌机下游戏才提供「轻触」交互：菜单可用触屏点选）。iOS 手机形态与之最接近。
    // Handheld mode: on a real Switch in handheld the game offers touch interaction (menus are tappable). An iPhone is
    // closest to that form factor.
    if (!getenv("DM_OPMODE")) setenv("DM_OPMODE", "0", 1);
}

// 诊断/验收：DM_TEST_HOVER="秒:x,y;..." 只把鼠标移到该位置（不按键），验证菜单「先悬停再点击」的时序。
// Diagnostic / acceptance: DM_TEST_HOVER=<seconds>:<x>,<y>[;...] moves the mouse there without pressing the button, to
// verify the menu's "hover first, then click" timing.
void dm_mouse_hover(float nx, float ny);
static void hover_schedule(void) {
    const char *e = getenv("DM_TEST_HOVER");
    if (!e || !*e) return;
    LOG("[test] 悬停脚本 %s", e);
    for (const char *q = e; q && *q; q = strchr(q, ';') ? strchr(q, ';') + 1 : NULL) {
        double at = atof(q); const char *c = strchr(q, ':'); float x = 0, y = 0;
        if (!c || sscanf(c + 1, "%f,%f", &x, &y) != 2) continue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dm_mouse_hover(x, y);
            LOG("[test] 第 %.1f 秒悬停 (%.3f,%.3f)", at, x, y);
        });
    }
}

// 点按补 A：按下就补（不等抬手、也不看按住时长），两拍 A 间隔 0.3 s、每拍 180 ms。
// VA-11 的「按 A 键开始游戏」等提示只认手柄 A；触屏点击是主输入，所以每次按下都补两拍 A。
// Tap-to-A: pulse as soon as the finger/mouse goes down (no dependence on release time or hold duration). Two A pulses
// 0.3 s apart, 180 ms each: VA-11 prompts like "press A to start" only accept gamepad A, and touch taps are the primary input.
void dm_kbd_press(int code, int ms);   // hle_hid.c：键盘注入（VA-11 runner 用键盘轮询）| keyboard injection (the VA-11 runner polls the keyboard)

static void tap_a_pulse(void) { tap_a_pulse_at(0.5f, 0.5f); }

static void tap_a_pulse_at(float nx, float ny) {
    // DM_NO_TAP_A=1（验收用）：点按不再补 A / Enter / Space / 帧同步点击。
    // 菜单是鼠标驱动时，补 A 会顺手选中默认项（实测：单次点按会直接进「读取」页），
    // 做点位验收时必须让「点按 = 只推触点���。
    // DM_NO_TAP_A=1 (acceptance only): a tap no longer pulses A / Enter / Space / the frame-synced click.
    // Menus are mouse-driven here; the extra A silently selects the default item (measured: a single tap jumps
    // straight to the Load page), so position acceptance needs "tap = touch only".
    { static int noa = -1; if (noa < 0) { const char *e = getenv("DM_NO_TAP_A"); noa = (e && *e) ? 1 : 0; } if (noa) { LOG("[test] 点按：DM_NO_TAP_A，不补 A"); return; } }
    // 抬手之后才补 A：按住期间给 A 会被游戏丢掉（实测「按 A 键开始游戏」不动）；与按住时长无关。
    // Pulse A only after the touch is released: an A press while the finger/mouse is still down is dropped by the game
    // (observed on the "press A to start" screen); independent of how long the press was held.
    // 6 拍 A（按下 120 ms、间隔 250 ms，共约 2 s）：标题提示会闪烁/存在状态窗口，单拍容易错过，连拍更稳。
    // Six A pulses (120 ms down, 250 ms apart, ~2 s total): the title prompt blinks / has state windows, so a single pulse
    // is easy to miss; a short burst is robust.
    { extern void dm_click_request(float, float); dm_click_request(nx, ny); }   // 帧同步鼠标点击（菜单点选用真实落点）| frame-synced mouse click (real hit point for menu selection)
    // 先让鼠标点击把菜单选择挪到落点，再补 A/Enter/Space：VA-11 的主菜单在收到 A 的同一拍会确认
    // **手柄当前选择位**（默认「读取」），所以补键必须等点击生效（实测提前补键会直接进读档页）。
    // Let the mouse click move the menu selection to the hit point before pulsing A/Enter/Space: on the same tick as an A
    // press VA-11's main menu confirms the controller's *current* selection (Load by default), so the pulses must wait for
    // the click to take effect (measured: pulsing early jumps straight to the Load page).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dm_kbd_press(0x28, 220);   // Enter（HID 0x28）：菜单/对话确认 | Enter (HID 0x28): menu/dialogue confirm
        dm_kbd_press(0x2C, 220);   // Space（HID 0x2C）：推进对白 | Space (HID 0x2C): advance dialogue
        for (int k = 0; k < 6; k++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.10 + 0.25 * k) * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                pad_press(DM_BTN_A);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    pad_release(DM_BTN_A);
                });
            });
        }
    });
}

// 诊断/验收：DM_TEST_STEP="at:<毫秒>;hover:x,y;wait:ms;click:x,y;tap;key:A;... "
// 一次启动里按顺序执行一串单步动作（不依赖窗口焦点、不用反复重启 App），用来脚本化验收菜单/设置/调酒。
// Diagnostic / acceptance: DM_TEST_STEP="at:<ms>;hover:x,y;wait:ms;click:x,y;tap;key:A;..." runs one ordered sequence of
// single-step actions in a single launch (independent of window focus, no app restarts), so menus/settings/bartending can be
// exercised repeatably.
static void step_schedule(void) {
    const char *e = getenv("DM_TEST_STEP");
    if (!e || !*e) return;
    LOG("[test] 单步脚本 %s", e);
    char *copy = strdup(e);
    char *save = NULL;
    char *tok = strtok_r(copy, ";", &save);
    long at_ms = 0;
    if (tok && strncmp(tok, "at:", 3) == 0) { at_ms = atol(tok + 3); tok = strtok_r(NULL, ";", &save); }
    // 收集剩余 token | collect the remaining tokens
    char **toks = (char **)calloc(64, sizeof(char *)); int ntok = 0;
    for (; tok && ntok < 64; tok = strtok_r(NULL, ";", &save)) toks[ntok++] = tok;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at_ms * 1000000ULL)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < ntok; i++) {
            char *t = toks[i];
            char *colon = strchr(t, ':');
            char op[16] = {0}; char arg[64] = {0};
            size_t n = colon ? (size_t)(colon - t) : strlen(t);
            if (n >= sizeof op) n = sizeof op - 1;
            memcpy(op, t, n);
            if (colon) strncpy(arg, colon + 1, sizeof arg - 1);
            if (strcmp(op, "wait") == 0) { usleep((useconds_t)(atol(arg) * 1000)); }
            else if (strcmp(op, "hover") == 0) { float x = 0, y = 0; if (sscanf(arg, "%f,%f", &x, &y) == 2) { dm_mouse_hover(x, y); LOG("[test] 步:悬停 (%.3f,%.3f)", x, y); } }
            else if (strcmp(op, "click") == 0 || strcmp(op, "tap") == 0) {
                dm_touch td = {0, 0.5f, 0.5f};
                if (strcmp(op, "click") == 0) { float x = 0, y = 0; if (sscanf(arg, "%f,%f", &x, &y) == 2) { td.x = x; td.y = y; } }
                LOG("[test] 步:%s (%.3f,%.3f)", op, td.x, td.y);
                // 250 ms 按住：GM 菜单用边沿检测（device_mouse_check_button_pressed），65 ms / 120 ms 可能整段落在两拍之间
                // 250 ms hold: GM menus use edge detection (device_mouse_check_button_pressed); 65/120 ms can fall between two ticks
                dm_touch_set(&td, 1); usleep(250000); dm_touch_set(NULL, 0);
                tap_a_pulse_at(td.x, td.y);   // 点按与真实触屏同一路径，并带真实落点 | same path as a real touch, carrying the real hit point
            }
            else if (strcmp(op, "key") == 0) { uint64_t m = pad_mask_of(arg); if (m) { pad_press(m); usleep(120000); pad_release(m); } }
            // kbd:<HID 键码>[,按住毫秒]：键盘注入（HID usage，40=Return、44=Space、82=Up、81=Down、80=Left、79=Right）
            // kbd:<HID usage>[,hold ms]: keyboard injection (HID usage; 40=Return, 44=Space, 82=Up, 81=Down, 80=Left, 79=Right)
            // stick:<lx>,<ly>[,毫秒]：推左摇杆（±32767），用于试「摇杆导航」的菜单
            // stick:<lx>,<ly>[,ms]: push the left stick (+-32767), for testing stick-driven menus
            // wintap:x,y：走「窗口级兜底」同一条注入路径（模拟器里验证归一化/日志/注入）
            // wintap:x,y: goes through the same injection path as the window-level fallback (validates normalisation/log/injection in the simulator)
            // mclick:x,y：只走鼠标（先 hover 定光标再帧同步点击），不推触点、不补 A —— 用来分离「鼠标坐标系」与「触点坐标系」
            // mclick:x,y: mouse only (hover to place the cursor, then a frame-synced click); no touch state, no A pulse -- separates the mouse coordinate space from the touch one
            else if (strcmp(op, "mclick") == 0) { float x = 0, y = 0; if (sscanf(arg, "%f,%f", &x, &y) == 2) { extern void dm_click_request(float, float); dm_mouse_hover(x, y); usleep(120000); dm_click_request(x, y); LOG("[test] 步:纯鼠标点击 (%.3f,%.3f)", x, y); } }
            else if (strcmp(op, "wintap") == 0) { float x = 0.5f, y = 0.5f; if (sscanf(arg, "%f,%f", &x, &y) == 2) { front_window_tap(x, y); } }
            else if (strcmp(op, "stick") == 0) { int lx = 0, ly = 0, ms = 400; if (sscanf(arg, "%d,%d,%d", &lx, &ly, &ms) >= 2) { extern void dm_pad_set(uint64_t, int32_t, int32_t, int32_t, int32_t); LOG("[test] 步:摇杆 (%d,%d) 保持 %d ms", lx, ly, ms); dm_pad_set(0, lx, ly, 0, 0); usleep((useconds_t)ms * 1000); dm_pad_set(0, 0, 0, 0, 0); } }
            else if (strcmp(op, "kbd") == 0) { int code = 0, ms = 150; if (sscanf(arg, "%d,%d", &code, &ms) >= 1) { LOG("[test] 步:键盘 0x%02x 按住 %d ms", code, ms); dm_kbd_press(code, ms); } }
            else LOG("[test] 步:未知 %s", t);
        }
        LOG("[test] 单步脚本执行完毕");
    });
}

// 诊断/验收：DM_TEST_TAP_REPEAT="start:interval:x,y[;...]" 从 start 秒起每 interval 秒点一次（模拟真人持续点按）。
// 启动到可交互的时间波动很大，固定时刻的脚本会大量落在 splash 上；重复点按保证交互阶段一定有输入。
// 与真实手指同一条路：dm_touch_set（鼠标面）+ 点按后 150 ms 补一次 120 ms 的 A（同 pushTouches 的产品逻辑）。
// Diagnostic / acceptance: DM_TEST_TAP_REPEAT=<start>:<interval>:<x>,<y>[;...] taps every <interval> seconds from <start>
// (like a person tapping repeatedly). Boot-to-interactive time varies a lot, so a fixed-time script often lands on the
// splash; repeated taps guarantee input during the interactive phase. Same path as a real finger: dm_touch_set (mouse
// surface) plus the product's 150 ms-delayed 120 ms A pulse after the tap.
static void tap_repeat_schedule(void) {
    const char *e = getenv("DM_TEST_TAP_REPEAT");
    if (!e || !*e) return;
    LOG("[test] 重复点按脚本 %s", e);
    for (const char *q = e; q && *q; q = strchr(q, ';') ? strchr(q, ';') + 1 : NULL) {
        double start = 0, iv = 6; float x = 0.5f, y = 0.5f;
        if (sscanf(q, "%lf:%lf:%f,%f", &start, &iv, &x, &y) != 4) continue;
        if (iv < 1) iv = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(start * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, (uint64_t)(iv * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(t, ^{
                LOG("[test] 重复点按 (%.3f,%.3f)", x, y);
                dm_touch td = {0, x, y};
                dm_touch_set(&td, 1);
                usleep(120000);
                dm_touch_set(NULL, 0);
                tap_a_pulse();   // 与真实触屏走同一补 A 实现（抬手后）| same tap-to-A path as a real touch (after release)
            });
            dispatch_resume(t);
        });
    }
}

// 诊断/验收：DM_TEST_PAD="秒:A;B;PLUS" 按脚本脉冲手柄键（120 ms），用来驱动「按 A 开始 / 继续对话」这类提示。
// Diagnostic / acceptance: DM_TEST_PAD=<seconds>:<A|B|X|Y|PLUS|MINUS>[...] pulses a gamepad button for 120 ms, to drive
// prompts such as "press A to start / advance".
static uint64_t pad_mask_of(const char *n) {
    if (!strcmp(n, "A")) return DM_BTN_A; if (!strcmp(n, "B")) return DM_BTN_B;
    if (!strcmp(n, "X")) return DM_BTN_X; if (!strcmp(n, "Y")) return DM_BTN_Y;
    if (!strcmp(n, "PLUS")) return DM_BTN_PLUS; if (!strcmp(n, "MINUS")) return DM_BTN_MINUS;
    if (!strcmp(n, "LEFT")) return DM_BTN_LEFT; if (!strcmp(n, "RIGHT")) return DM_BTN_RIGHT;
    if (!strcmp(n, "UP")) return DM_BTN_UP; if (!strcmp(n, "DOWN")) return DM_BTN_DOWN;
    return 0;
}
static void pad_schedule(void) {
    const char *e = getenv("DM_TEST_PAD");
    if (!e || !*e) return;
    LOG("[test] 手柄脚本 %s", e);
    for (const char *q = e; q && *q; q = strchr(q, ';') ? strchr(q, ';') + 1 : NULL) {
        double at = atof(q); const char *c = strchr(q, ':');
        if (!c) continue;
        char nm[16] = {0}; sscanf(c + 1, "%15[A-Za-z]", nm);   // 只读到字母：后面还有 ;下一个时刻 | read letters only: a ;<next time> follows
        uint64_t m = pad_mask_of(nm);
        if (!m) continue;
        double hold = 0.12;   // 缺省短脉冲；「A+1.5」= 按住 1.5 秒（判别「输入时序 vs 对白 HLE」用） | default short pulse; "A+1.5" = hold 1.5 s (to tell input timing from a dialogue-HLE block)
        { const char *end = strchr(c, ';'); size_t n = end ? (size_t)(end - c) : strlen(c);
          char item[32] = {0}; if (n < sizeof item) { memcpy(item, c, n); item[n] = 0; }
          const char *plus = strchr(item, '+');   // 只在当前项里找：旧实现会串到下一项的 '+' | search only this item: the old code picked up a '+' from a later item
          if (plus && atof(plus + 1) > 0) hold = atof(plus + 1); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            LOG("[test] 第 %.1f 秒按手柄键 %#llx（按住 %.2f 秒）", at, (unsigned long long)m, hold);
            pad_press(m);
            usleep((useconds_t)(hold * 1e6));
            pad_release(m);
        });
    }
}

// ---------- 客体启动线程 ----------
static void *boot_thread(void *unused) {
    (void)unused;
    fprintf(stderr, "[boot] 起客体：dm_main %s\n", g_arg[1]);
    int rc = dm_main(g_argc, g_arg);
    fprintf(stderr, "[boot] dm_main 返回 %d\n[boot] DONE\n", rc);
    return NULL;
}
static void start_boot(void) {
    if (g_boot_started) return;
    g_boot_started = 1;
    payload_check();
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64 << 20);
    pthread_t t;
    if (pthread_create(&t, &a, boot_thread, NULL)) { fprintf(stderr, "[boot] 【红】起客体线程失败\n"); return; }
    pthread_detach(t);
}

// ---------- App ----------
@interface Va11AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
- (void)layoutGame;
- (void)onWindowTap:(UITapGestureRecognizer *)g;
@end

@implementation Va11AppDelegate
// 窗口级兜底手势的处理：把触点换算成画面归一化坐标后注入（与手指路径一致），300 ms 内视图已收到就跳过。
// Handler for the window-level fallback gesture: normalise the point and inject through the same path as a finger,
// skipping when the view already received a real touch within 300 ms.
// 窗口级兜底注入的共用实现（手势与 DM_TEST_STEP 的 wintap 步都走这里）
// Shared implementation of the window-level fallback injection (used by the gesture and by the wintap test step)
static void front_window_tap(float nx, float ny) {
    nx = nx < 0 ? 0 : nx > 0.999f ? 0.999f : nx; ny = ny < 0 ? 0 : ny > 0.999f ? 0.999f : ny;
    LOG("[front] 窗口手势兜底 (%.3f,%.3f)", nx, ny);
    dm_touch td = {0, nx, ny};
    dm_touch_set(&td, 1); usleep(140000); dm_touch_set(NULL, 0);
    tap_a_pulse_at(nx, ny);
}
- (void)onWindowTap:(UITapGestureRecognizer *)g {
    extern _Atomic uint64_t g_front_touch_ns;
    uint64_t last = atomic_load(&g_front_touch_ns);
    if (last && now_ns() - last < 300000000ull) return;   // 视图已经收到真实触摸，不重复 | the view already got the real touch: skip
    CGPoint p = [g locationInView:g_view];
    CGFloat w = g_view.bounds.size.width, h = g_view.bounds.size.height;
    front_window_tap(w > 0 ? (float)(p.x / w) : 0.5f, h > 0 ? (float)(p.y / h) : 0.5f);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    g_win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.blackColor;
    g_root = vc.view;
    g_win.rootViewController = vc;
    self.window = g_win;   // 老式 App 入口：窗口要挂到 delegate 上，否则可能不显示（黑屏） | legacy App entry: the window must be attached to the delegate or nothing may show (black screen)

    // 出图视图：逻辑尺寸就是游戏分辨率（1600x900），contentsScale 压到 1 —— 主机模式像素与逻辑 1:1，
    // 再用 transform 等比缩到屏幕上（16:9 以外的地方留黑边），触摸按视图坐标换算，与缩放无关。
    // Output view: its logical size IS the game resolution (1600x900) with contentsScale pinned to 1 -- in docked mode
    // pixels map 1:1 to points -- then scaled uniformly onto the screen with a transform (black bars outside 16:9);
    // touches are converted in view coordinates, independent of the scale.
    Va11GLView *v = [[Va11GLView alloc] initWithFrame:CGRectMake(0, 0, kGameW, kGameH)];
    v.contentScaleFactor = 1;
    g_view = v;
    g_layer = (CAEAGLLayer *)v.layer;
    g_layer.contentsScale = 1;   // 画布尺寸 = bounds × contentsScale（CAEAGLLayer 没有 drawableSize，那是 CAMetalLayer 的属性）
    [g_root addSubview:v];
    [g_win makeKeyAndVisible];
    [g_win layoutIfNeeded];
    [self layoutGame];
    hle_egl_set_view((__bridge void *)g_view);
    { int hle_egl_prepare_on_main(void); hle_egl_prepare_on_main(); }   // 主线程建上下文与画布（见 hle_egl_ios.m） | build the context and canvas on the main thread (see hle_egl_ios.m)
    // 窗口级兜底：某些侧载器（LiveContainer 等）把触摸事件留在自己的窗口层，GL 视图收不到。
    // 在窗口上挂一个 tap 手势，把触点按视图坐标归一化后走同一条注入路径；300 ms 内视图已收到真实触点就跳过（不重复）。
    // Window-level fallback: some sideloaders (LiveContainer and friends) keep touches on their own window layer so the
    // GL view never sees them. A tap gesture on the window normalises the point the same way and injects through the same
    // path; if the view already saw a real touch within 300 ms the gesture is skipped (no double handling).
    { UITapGestureRecognizer *tg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onWindowTap:)];
      tg.cancelsTouchesInView = NO; tg.delaysTouchesEnded = NO;
      [g_win addGestureRecognizer:tg]; }
    if (getenv("DM_VIRTUAL_PAD")) [self buildTouchControls];   // 手柄键只作诊断/对照，缺省不显示（触屏点击是主输入） | gamepad buttons are diagnostics/comparison only, hidden by default (touch clicks are the primary input)
    LOG("[front] EAGL 视图就绪（%dx%d 逻辑）", kGameW, kGameH);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    // 注意：不要调 dm_gfx_suspend —— 那是 NVN→Metal 层的挂起；VA-11 走 GL，nvn 层从未初始化，
    // mtl_drain→mtl_init 会直接 abort（实测点了设置、App 被切到后台时进程崩了一次）。只冻结时钟与音频。
    // Note: do NOT call dm_gfx_suspend -- that suspends the NVN->Metal layer; VA-11 renders through GL and the NVN layer
    // is never initialised, so mtl_drain->mtl_init aborts (one crash observed when the app was backgrounded mid-tap).
    // Only the guest clock and audio are suspended.
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("前端：进后台 → 冻结 / 暂停音频"); dm_focus_set(3); dm_audio_suspend(1);
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("前端：回前台 → 恢复"); dm_audio_suspend(0); dm_focus_set(1);
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(1); }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(2); }];

    dispatch_async(dispatch_get_main_queue(), ^{ start_boot(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tap_schedule(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ pad_schedule(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ hover_schedule(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tap_repeat_schedule(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ step_schedule(); });
    return YES;
}

// 触屏虚拟键布局：A（确认/继续，大）、B（返回，小）、＋（菜单，小）固定在右下角；半透明，不挡画面中心。
// 触摸覆盖层只在按钮自己的区域吃事件（容器 hitTest 返回 nil），画面其余部分的触点照常进游戏（= 鼠标）。
// Virtual button layout: A (confirm/advance, large), B (back, small), + (menu, small) pinned to the bottom-right corner;
// translucent so the picture centre stays clear. The overlay only takes touches inside the buttons (the container's
// hitTest returns nil), so touches on the rest of the picture still reach the game (= the mouse).
- (void)buildTouchControls {
    TouchHudBox *box = [[TouchHudBox alloc] initWithFrame:g_root.bounds];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    box.backgroundColor = UIColor.clearColor;
    box.multipleTouchEnabled = YES;
    struct { const char *title; uint64_t mask; CGFloat d; UIColor *c; } defs[] = {
        {"A", DM_BTN_A, 76, [UIColor colorWithRed:0.96 green:0.36 blue:0.55 alpha:0.38]},
        {"B", DM_BTN_B, 56, [UIColor colorWithRed:0.30 green:0.85 blue:0.95 alpha:0.34]},
        {"+", DM_BTN_PLUS, 46, [UIColor colorWithWhite:0.9 alpha:0.30]},
    };
    CGFloat x = g_root.bounds.size.width, y = g_root.bounds.size.height;
    CGFloat dx[3] = {x - 78, x - 186, x - 92};
    CGFloat dy[3] = {y - 78, y - 66, y - 210};
    // 左下角十字键：菜单与光标导航（方向键 = nn::hid 的 Left/Up/Right/Down）
    // D-pad in the bottom-left corner: menu and cursor navigation (the D-pad buttons are nn::hid's Left/Up/Right/Down)
    struct { const char *title; uint64_t mask; CGFloat x, y; } dirs[] = {
        {"<", DM_BTN_LEFT, 118, y - 78}, {">", DM_BTN_RIGHT, 238, y - 78},
        {"^", DM_BTN_UP, 178, y - 138}, {"v", DM_BTN_DOWN, 178, y - 20},
    };
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat d = 54;
        b.frame = CGRectMake(dirs[i].x - d / 2, dirs[i].y - d / 2, d, d);
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        b.backgroundColor = [UIColor colorWithWhite:0.9 alpha:0.22];
        b.layer.cornerRadius = d / 2;
        b.layer.borderWidth = 1.2;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        [b setTitle:@(dirs[i].title) forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        b.tag = (NSInteger)dirs[i].mask;
        [b addTarget:self action:@selector(padTouchDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(padTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [box addSubview:b];
    }
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(dx[i] - defs[i].d / 2, dy[i] - defs[i].d / 2, defs[i].d, defs[i].d);
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        b.backgroundColor = defs[i].c;
        b.layer.cornerRadius = defs[i].d / 2;
        b.layer.borderWidth = 1.2;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        [b setTitle:@(defs[i].title) forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:defs[i].d * 0.42];
        b.tag = (NSInteger)defs[i].mask;
        [b addTarget:self action:@selector(padTouchDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(padTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [box addSubview:b];
    }
    [g_root addSubview:box];
    g_touch_hud = box;
}

// 等比摆放：游戏画面按 16:9 放进屏幕（比例对得上就是整个屏幕，对不上四周留黑边）。
// Uniform layout: fit the 16:9 picture into the screen (the whole screen when the ratios match, black bars otherwise).
- (void)layoutGame {
    if (!g_root || !g_view) return;
    CGSize b = g_root.bounds.size;
    if (b.width <= 0 || b.height <= 0) return;
    CGFloat sc = MIN(b.width / kGameW, b.height / kGameH);
    if (sc <= 0) return;
    g_view.transform = CGAffineTransformMakeScale(sc, sc);
    g_view.center = CGPointMake(b.width / 2, b.height / 2);
}
- (void)padTouchDown:(UIButton *)b { pad_press((uint64_t)b.tag); }
- (void)padTouchUp:(UIButton *)b { pad_release((uint64_t)b.tag); }
- (void)applicationDidBecomeActive:(UIApplication *)application { (void)application; [self layoutGame]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        boot_env();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(Va11AppDelegate.class));
    }
}
