// nn::vi（显示层）：真机经 vi 服务开显示、建图层、取原生窗口句柄；句柄交给 NVN 的窗口 builder。
// 宿主：返回宿主静态对象；接 Metal 时原生窗口对应前端的 CAMetalLayer（front_metal_layer()）。
// nn::vi (display layer): on a real device, the vi service is used to open the display, create a layer and get the native window handle; the handle is passed to NVN's window builder.
// Host: returns host static objects; when hooking up Metal, the native window corresponds to the front end's CAMetalLayer (front_metal_layer()).
#include "../host/hle.h"

static struct { uint32_t magic; } g_display = {0x50534944}, g_layer = {0x5259414c};
static struct { uint32_t magic; void *layer; } g_native = {0x4e49574e, 0};

HLE_FORCE("_ZN2nn2vi10InitializeEv", "显示服务初始化；宿主无 vi 服务", void, h_vi_Init, void) {}
HLE_FORCE("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", "开默认显示；宿主给静态对象", Result, h_vi_OpenDisp, void **out) {
    *out = &g_display; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", "建图层；宿主给静态对象", Result, h_vi_CreateLayer, void **out, void *disp) {
    (void)disp; *out = &g_layer; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", "原生窗口句柄，交给 NVN 窗口 builder；宿主给静态对象", Result, h_vi_GetNative, void **out, void *layer) {
    (void)layer; *out = &g_native; return RES_OK;
}

// VA-11 移植：GM runner 会直接调 sdk 的 vi 客户端代码（D2R 只走上面四个高层封装）。
// SetLayerScalingMode 内部走 GetService，宿主把 vi::Initialize 空置后返回空实例 → 接管为空操作。
// VA-11 port: the GM runner calls the sdk's vi client code directly (D2R only goes through the four wrappers above).
// SetLayerScalingMode goes through GetService internally, which returns a null instance once vi::Initialize is stubbed → take it over as a no-op.
HLE_FORCE("_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE", "VA-11：宿主静态图层，缩放模式空操作", Result, h_vi_SetScalingMode, void *layer, int mode) {
    (void)layer; (void)mode; return RES_OK;
}
