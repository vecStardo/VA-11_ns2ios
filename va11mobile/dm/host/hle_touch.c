// 触屏：前端整组推触点（dm_touch_set，front.h），游戏每帧经 nn::hid::GetTouchScreenStates 读（hle_hid.c → touch_fill）。
// 游戏的读法（main 0x1b65260）：清 16 份状态、要 16 份，只看第 0 份——触点数与各触点的 finger_id / x / y；面板坐标系 1280x720
// （它在同一函数里写常量 0x2d0_00000500 = 720 << 32 | 1280）。所以：
//   · 前端归一化坐标 [0,1)（出图画面左上为原点）→ x = nx·1280、y = ny·720，夹到 [0,1279] / [0,719]；
//   · 短按锁存：游戏只看最新一份，两次读之间按下又抬起的手指若不锁存会整个丢掉——本表每根手指先以 Start 报一次，
//     抬起后再以 End 报一次才释放（两次读之间按下又抬起 = 这次报 Start、下次报 End）。
// TouchState（0x28 字节，= libnx HidTouchState）：+0 delta_time（ns，i64）、+8 属性（bit0 Start / bit1 End）、+0xc finger_id、
// +0x10 x、+0x14 y、+0x18 直径 x、+0x1c 直径 y、+0x20 转角、+0x24 保留。TouchScreenState<16>：+0 采样号、+8 触点数、+0x10 起 16 个 TouchState。
// Touchscreen: the front end pushes the whole set of touch points (dm_touch_set, front.h), and the game reads them every frame through nn::hid::GetTouchScreenStates (hle_hid.c → touch_fill).
// How the game reads (main 0x1b65260): it clears 16 states, asks for 16, and looks only at state 0 -- the touch count and each touch point's finger_id / x / y; the panel coordinate system is 1280x720
// (it writes the constant 0x2d0_00000500 = 720 << 32 | 1280 in the same function). Therefore:
//   · front-end normalized coordinates [0,1) (origin at the top left of the output picture) → x = nx·1280, y = ny·720, clamped to [0,1279] / [0,719];
//   · short-press latch: the game only looks at the newest state, so a finger pressed and lifted between two reads would be lost entirely without a latch -- in this table every finger is first reported once as Start,
//     and is released only after being reported once more as End after lifting (pressed and lifted between two reads = Start in this report, End in the next).
// TouchState (0x28 bytes, = libnx HidTouchState): +0 delta_time (ns, i64), +8 attributes (bit0 Start / bit1 End), +0xc finger_id,
// +0x10 x, +0x14 y, +0x18 diameter x, +0x1c diameter y, +0x20 rotation angle, +0x24 reserved. TouchScreenState<16>: +0 sample number, +8 touch count, 16 TouchState from +0x10.
#include "dm.h"
#include "front.h"
#include <pthread.h>
#include <stdatomic.h>
unsigned long long dm_guest_frame(void);
static int32_t clampi(float v, int hi);   // 前向声明：点击队列在定义前用到 | forward declaration: the click queue uses it before the definition
enum { F_EMPTY, F_DOWN, F_LIFTED };
static struct { int st, reported, again; float x, y, ax, ay; } g_f[16];
// 鼠标面状态（见下面 dm_touch_mouse）：最新触点位置与按键，抬起后位置保留 | mouse-surface state (see dm_touch_mouse below)
static int32_t g_mx, g_my; static int g_mdown, g_mhave;
// d2r 的做法（dm/ios front_ios.m 注释 / dm_cursor.c dm_ui_mouse_pump）：前端页面的点击不在前端线程直接生效，
// 而是排进队列、在「游戏取手柄那一拍」按出图帧推进 —— 按下 / 按住 / 抬起各占若干帧，保证游戏一定采样到干净的按下沿。
// 这里给 VA-11 加同样的帧同步点击队列：dm_click_request 只登记，真正的鼠标按钮状态由 mouse_fill（游戏每拍轮询）推进。
// How d2r does it (dm/ios front_ios.m comment / dm_cursor.c dm_ui_mouse_pump): a front-end click is not applied on the front
// thread; it is queued and advanced per presented frame at the controller read, with press/hold/release each taking several
// frames so the game always samples a clean press edge. The same frame-synchronised click queue is added here: dm_click_request
// only registers, and mouse_fill (polled by the game every tick) advances the actual mouse button state.
static _Atomic int g_click_phase;   // 0 空闲；1 按下；2 按住；3 抬起 | 0 idle, 1 press, 2 hold, 3 release
static _Atomic float g_click_x, g_click_y;
void dm_click_request(float nx, float ny) {
    g_click_x = nx; g_click_y = ny;
    atomic_store(&g_click_phase, 1);
}
// 按「出图帧」推进：同一帧里多次取鼠标只算一拍（一次 GetMouseStates 可能被调用多层，不能每层都推进）
// Advance per presented frame: several mouse reads within one frame count as one tick (GetMouseStates may be called several
// times per frame, and it must not advance every call).
int dm_click_step(int *down_x, int *down_y) {
    static uint64_t last_fr; static int held;
    int ph = atomic_load(&g_click_phase);
    if (!ph) { held = 0; return 0; }
    uint64_t fr = dm_guest_frame();
    int advanced = 0;
    if (fr != last_fr) { last_fr = fr; advanced = 1; }
    if (!advanced) { if (!held) return 0; if (down_x) *down_x = clampi(atomic_load(&g_click_x), 1279); if (down_y) *down_y = clampi(atomic_load(&g_click_y), 719); return 1; }
    if (ph == 1) { atomic_store(&g_click_phase, 2); held = 1; }
    else if (ph == 2) { atomic_store(&g_click_phase, 3); held = 1; }
    else { atomic_store(&g_click_phase, 0); held = 0; return 0; }
    if (down_x) *down_x = clampi(atomic_load(&g_click_x), 1279);
    if (down_y) *down_y = clampi(atomic_load(&g_click_y), 719);
    return 1;
}

static int32_t clampi(float v, int hi);   // again/ax/ay：End 还没报出去时同 id 又按下（下次读先报 End 再报新 Start） | again/ax/ay: the same id was pressed again before End went out (the next read reports End first, then the new Start)
static pthread_mutex_t g_tl = PTHREAD_MUTEX_INITIALIZER;
static int64_t g_tsamp; static uint64_t g_tlast_ns;

void dm_touch_set(const dm_touch *t, int n) {
    {   // 诊断：每次前端/脚本推触点都记一行（按下/抬起、坐标），定位「卡住的触点」来自哪条路径
        // Diagnostic: log every touch-set push (down/up, coordinates) to find which path leaves a stuck touch
        static int lg = -1; if (lg < 0) lg = getenv("DM_TOUCH_TRACE") != NULL;
        if (lg) {
            if (n > 0 && t) LOG("[touch-trace] 推 %d 点 #0 id=%u (%.3f,%.3f)", n, t[0].id, t[0].x, t[0].y);
            else LOG("[touch-trace] 推 0 点（抬起全部）");
        }
    }
    pthread_mutex_lock(&g_tl);
    int seen[16] = {0};
    for (int i = 0; i < n; i++) {
        uint32_t id = t[i].id; if (id >= 16) continue;
        seen[id] = 1;
        if (g_f[id].st == F_LIFTED && g_f[id].reported) { g_f[id].again = 1; g_f[id].ax = t[i].x; g_f[id].ay = t[i].y; continue; }
        if (g_f[id].st == F_EMPTY) { g_f[id].st = F_DOWN; g_f[id].reported = 0; }
        else if (g_f[id].st == F_LIFTED) g_f[id].st = F_DOWN;              // 抬起还没报过又按下：当作一直按着 | Pressed again before the lift was reported: treat it as held down all along
        g_f[id].x = t[i].x; g_f[id].y = t[i].y;
    }
    {   // 鼠标面：取本组第一个触点（按下取最小槽）当鼠标位置；任一点按着 = 左键按下 | mouse surface: first point of the set (lowest slot on down) is the mouse position; any point down = left button down
        int first = -1; for (int id = 0; id < 16; id++) if (seen[id]) { first = id; break; }
        if (first >= 0) { g_mx = clampi(t[first].x, 1279); g_my = clampi(t[first].y, 719); g_mhave = 1; g_mdown = 1; }
        else g_mdown = 0;
    }
    for (int id = 0; id < 16; id++) {
        if (!seen[id] && g_f[id].st == F_DOWN) g_f[id].st = F_LIFTED;
        if (!seen[id] && g_f[id].again) g_f[id].again = 0;                   // 重按后又抬起（End 都还没报）：重按丢掉，仍按原抬起报 End | Pressed again and then lifted again (End not even reported yet): drop the re-press, still report End for the original lift
    }
    pthread_mutex_unlock(&g_tl);
}

// 鼠标面（GM runner 的 mouse 输入）：把最新触点当成鼠标位置与左键。位置抬起后保留（鼠标停在原地、按键松开），
// 供 hle_hid.c 的 nn::hid::GetMouseStates 取。VA-11 是点选式玩法，触屏要能「点」必须把触点报成鼠标。
// Mouse surface (the GM runner's mouse input): treat the latest touch point as the mouse position and the left button.
// The position stays after the lift (the mouse stays put, the button is released) for nn::hid::GetMouseStates in
// hle_hid.c. VA-11 is point-and-click, so touch must be reported as a mouse for a tap to be a click.
int dm_touch_mouse(int *x, int *y, int *down) {
    pthread_mutex_lock(&g_tl);
    int have = g_mhave, mx = g_mx, my = g_my, dn = g_mdown;
    pthread_mutex_unlock(&g_tl);
    if (x) *x = mx; if (y) *y = my; if (down) *down = dn;
    return have;
}

static int32_t clampi(float v, int hi);
// 悬停（诊断/验收用）：只更新鼠标位置、不改按键——用来验证「先 hover 再 click」这类菜单时序。
// Hover (diagnostic / acceptance): update the mouse position without touching the button, to verify "hover first, then
// click" menu timing.
void dm_click_request(float nx, float ny);

void dm_mouse_hover(float nx, float ny) {
    pthread_mutex_lock(&g_tl);
    g_mx = clampi(nx, 1279); g_my = clampi(ny, 719); g_mhave = 1;
    pthread_mutex_unlock(&g_tl);
}

static int32_t clampi(float v, int hi) { int32_t r = (int32_t)(v * (float)(hi + 1)); return r < 0 ? 0 : r > hi ? hi : r; }
// 填一份 TouchScreenState<16>（out 按 0x290 字节）；now_ns 用于 delta_time。返回写入的触点数
// Fill one TouchScreenState<16> (out is 0x290 bytes); now_ns is used for delta_time. Returns the number of touch points written
int touch_fill(void *out, uint64_t now_ns) {
    uint8_t *o = out; memset(o, 0, 0x290);
    pthread_mutex_lock(&g_tl);
    int64_t samp = ++g_tsamp; int64_t dt = g_tlast_ns ? (int64_t)(now_ns - g_tlast_ns) : 0; g_tlast_ns = now_ns;
    int k = 0;
    for (int id = 0; id < 16; id++) {
        if (g_f[id].st == F_EMPTY) continue;
        uint32_t attr = 0;
        if (!g_f[id].reported) { attr |= 1; g_f[id].reported = 1; }          // Start（本次第一次报） | Start (reported for the first time this time)
        else if (g_f[id].st == F_LIFTED) attr |= 2;                         // End（已报过 Start、已抬起） | End (Start already reported, already lifted)
        uint8_t *s = o + 0x10 + 0x28 * k++;
        int32_t x = clampi(g_f[id].x, 1279), y = clampi(g_f[id].y, 719), d = 30, zero = 0, fid = id + 1;   // 真机 finger_id 从 1 起；0 可能被游戏当成无效 | real console finger ids start at 1; 0 may be treated as invalid
        memcpy(s + 0x00, &dt, 8); memcpy(s + 0x08, &attr, 4); memcpy(s + 0x0c, &fid, 4);
        memcpy(s + 0x10, &x, 4); memcpy(s + 0x14, &y, 4); memcpy(s + 0x18, &d, 4); memcpy(s + 0x1c, &d, 4); memcpy(s + 0x20, &zero, 4);
        if (attr & 2) {                                                      // End 报过：释放；若期间同 id 又按下，转成新的按下 | End has been reported: release; if the same id was pressed again in the meantime, turn it into a new press
            if (g_f[id].again) { g_f[id].st = F_DOWN; g_f[id].reported = 0; g_f[id].again = 0; g_f[id].x = g_f[id].ax; g_f[id].y = g_f[id].ay; }
            else g_f[id].st = F_EMPTY;
        }
    }
    pthread_mutex_unlock(&g_tl);
    int32_t cnt = k; memcpy(o + 0, &samp, 8); memcpy(o + 8, &cnt, 4);
    // DM_TOUCH_LOG=1（验收诊断）：非 0 触点的读逐次记一行——采样号、触点数、各点 finger_id / 面板 x,y / 属性（1 Start、2 End）；封顶 500 行
    // DM_TOUCH_LOG=1 (acceptance diagnostics): each read with non-zero touch points logs one line -- sample number, touch count, and for each point finger_id / panel x,y / attributes (1 Start, 2 End); capped at 500 lines
    static int lg = -1, nl; if (lg < 0) lg = getenv("DM_TOUCH_LOG") != NULL;
    if (lg && k && nl < 500) {
        char b[256]; int m = snprintf(b, sizeof b, "触屏读 采样 %lld 触点 %d", (long long)samp, k);
        for (int i = 0; i < k && m < (int)sizeof b - 40; i++) { int32_t v[4]; memcpy(v, o + 0x10 + 0x28 * i + 0x08, 16);
            m += snprintf(b + m, sizeof b - m, " | #%d (%d,%d) 属性 %d", v[1], v[2], v[3], v[0]); }
        LOG("%s", b); if (++nl == 500) LOG("DM_TOUCH_LOG 满 500 行，停记");
    }
    return k;
}
