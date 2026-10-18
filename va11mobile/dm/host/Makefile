# VA-11 HALL-A iOS 移植的宿主构建（基于 D2R Mobile 的宿主，剔除 D2R 专属功能文件）。
# Host build for the VA-11 HALL-A iOS port (based on the D2R Mobile host, with D2R-specific feature files removed).
# Core: 装载器 / 系统调用与系统服务接管 / Mac 前端 / 触摸。图形层与第三方解压库沿用 dm/gfx 与 libdeflate。
# Core: loader / syscall & service take-over / Mac front end / touch. The graphics layer and libdeflate come from dm/gfx.
MACOS_MIN ?= 26.0
CFLAGS=-O1 -g -Wall -Wno-unused-function -mmacosx-version-min=$(MACOS_MIN)
MACOS_MIN_M3 ?= 15.0
CFLAGS_M3=$(subst -mmacosx-version-min=$(MACOS_MIN),-mmacosx-version-min=$(MACOS_MIN_M3),$(CFLAGS)) -DDM_NVN_M3=1 -DDM_FOREIGN_GAME=1 -DAPP_NAME='"VA-11 HALL-A Mobile"'
APP_NAME_VAL='"VA-11 HALL-A Mobile"'

SRC=\
	app_mac.m \
	crash.c \
	diag.c \
	entry.S \
	front_mac.m \
	hle.c \
	hle_egl.m \
	hle_va11.m \
	loader.c \
	main.c \
	memstat.m \
	romfs_validate.c \
	thread.c \
	touch_mac.c \
	../ios/Sources/cloud_ios.m \
	../ios/Sources/dm_gamepad.m \
	../ios/Sources/dm_touch_controls.c \
	dm_actions.c \
	dm_autobuff.c \
	dm_beltauto.c \
	dm_bossrush.c \
	dm_bright.c \
	dm_cloudmerge.c \
	dm_cloudsync.c \
	dm_cursor.c \
	dm_cursor_item.c \
	dm_custom.c \
	dm_dropfilter.c \
	dm_drophaptic.c \
	dm_elysium.c \
	dm_freetp.c \
	dm_hud.c \
	dm_i18n.c \
	dm_kills.c \
	dm_lootfilter.c \
	dm_namegen.c \
	dm_padmode.c \
	dm_pages.c \
	dm_potpick.c \
	dm_pouch.c \
	dm_prof.c \
	dm_rift.c \
	dm_rift_ui.c \
	dm_runeword.c \
	dm_rwlv_core.c \
	dm_shoprefresh.c \
	dm_textbox.c \
	dm_textbox_core.c \
	dm_textinput.c \
	dm_townwp.c \
	dm_turnsmooth.c \
	dm_uiscreen.c \
	dm_update.c \
	dm_vault.c \
	dm_vault_ui.c \
	dm_world.c \
	$(sort $(wildcard hle_*.c))

GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m))
GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/include/*.h ../gfx/tex/*.h))
LIBDEFLATE=../third_party/libdeflate/lib/deflate_decompress.c ../third_party/libdeflate/lib/zlib_decompress.c ../third_party/libdeflate/lib/adler32.c ../third_party/libdeflate/lib/utils.c ../third_party/libdeflate/lib/arm/cpu_features.c

.DEFAULT_GOAL := dmhost_m3
print-macos-min-m3:
	@echo $(MACOS_MIN_M3)

dmhost_m3: $(SRC) $(GFX) $(LIBDEFLATE) dm.h hle.h dm_input.h front.h touch_mac.h $(GFX_H)
	clang $(CFLAGS_M3) -DAPP_NAME=$(APP_NAME_VAL) -I. -I../gfx/nvn/include -fobjc-arc -o $@ $(SRC) $(GFX) $(LIBDEFLATE) -framework Cocoa -framework QuartzCore -framework Metal -framework AudioToolbox -framework CoreAudio -framework ImageIO -framework UniformTypeIdentifiers -framework GameController -framework Network -framework AVFoundation -framework OpenGL
