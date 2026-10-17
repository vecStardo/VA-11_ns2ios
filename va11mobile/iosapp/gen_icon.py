#!/usr/bin/env python3
# 生成 App 图标与启动画面素材（原创的排版图形，不复制游戏美术）：
#   Assets.xcassets/AppIcon.appiconset/AppIcon1024.png   1024² 不透明应用图标（iOS 单尺寸）
#   Assets.xcassets/LaunchBackground.colorset           启动画面底色（深蓝黑）
#   Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png  启动画面居中的字标
# 用法：python3 gen_icon.py（build.sh 不需要每次跑，素材进仓）
# Generate the app icon and launch-screen assets (original typographic artwork, no game art copied):
#   Assets.xcassets/AppIcon.appiconset/AppIcon1024.png   1024² opaque app icon (iOS single size)
#   Assets.xcassets/LaunchBackground.colorset           launch-screen background (deep blue-black)
#   Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png  wordmark centred on the launch screen
# Usage: python3 gen_icon.py (build.sh does not need to run it every time; the assets are committed)
import json, os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
AS = os.path.join(HERE, 'Assets.xcassets')
BG = (11, 13, 26)        # 深蓝黑（游戏标题画面的夜色） | deep blue-black (the title screen's night colour)
CYAN = (60, 232, 226)
PINK = (255, 62, 128)
WHITE = (238, 238, 246)
DIM = (30, 34, 58)


def font(size):
    for p in ('/System/Library/Fonts/Supplemental/Arial Bold.ttf',
              '/System/Library/Fonts/Supplemental/Helvetica.ttc',
              '/System/Library/Fonts/SFNS.ttf'):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def centred(d, xy, text, f, fill):
    box = d.textbbox((0, 0), text, font=f)
    d.text((xy[0] - (box[2] - box[0]) / 2 - box[0], xy[1] - (box[3] - box[1]) / 2 - box[1]), text, font=f, fill=fill)


def icon(path, size=1024):
    im = Image.new('RGB', (size, size), BG)
    d = ImageDraw.Draw(im)
    # 背景：底部霓虹条 + 上半斜切色块（原创排版，不描游戏标志） | background: neon bar at the bottom, diagonal band on top
    d.polygon([(0, size * 0.10), (size, 0), (size, size * 0.20), (0, size * 0.30)], fill=DIM)
    d.rectangle([0, size * 0.86, size, size], fill=(18, 20, 40))
    for i, c in enumerate((CYAN, PINK, CYAN, PINK, CYAN)):
        x = size * (0.06 + i * 0.19)
        d.rectangle([x, size * 0.855, x + size * 0.10, size * 0.95], fill=c)
    centred(d, (size / 2, size * 0.44), 'VA-11', font(size * 0.30), WHITE)
    centred(d, (size / 2, size * 0.66), 'HALL-A', font(size * 0.20), CYAN)
    centred(d, (size / 2, size * 0.79), 'MOBILE', font(size * 0.075), PINK)
    im.save(path, 'PNG')


def logo(path, w=720, h=300):
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    centred(d, (w / 2, h * 0.34), 'VA-11', font(h * 0.42), WHITE + (255,))
    centred(d, (w / 2, h * 0.68), 'HALL-A', font(h * 0.24), CYAN + (255,))
    for i, c in enumerate((CYAN, PINK, CYAN, PINK, CYAN)):
        x = w * 0.30 + i * w * 0.09
        d.rectangle([x, h * 0.86, x + w * 0.05, h * 0.93], fill=c + (255,))
    im.save(path, 'PNG')


def write_json(p, obj):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as f:
        json.dump(obj, f, indent=2)
        f.write('\n')


def main():
    write_json(os.path.join(AS, 'Contents.json'), {'info': {'author': 'xcode', 'version': 1}})
    # 图标（iOS 单尺寸：universal 1024 marketing） | icon (iOS single size: universal 1024 marketing)
    ic = os.path.join(AS, 'AppIcon.appiconset')
    os.makedirs(ic, exist_ok=True)
    icon(os.path.join(ic, 'AppIcon1024.png'))
    write_json(os.path.join(ic, 'Contents.json'), {
        'images': [{'filename': 'AppIcon1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
        'info': {'author': 'xcode', 'version': 1}})
    # 启动画面底色 | launch-screen background colour
    bg = os.path.join(AS, 'LaunchBackground.colorset')
    os.makedirs(bg, exist_ok=True)
    write_json(os.path.join(bg, 'Contents.json'), {
        'colors': [{'color': {'color-space': 'srgb', 'components': {
            'alpha': '1.000', 'blue': '0x1A', 'green': '0x0D', 'red': '0x0B'}}, 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1}})
    # 启动画面字标 | launch-screen wordmark
    lg = os.path.join(AS, 'LaunchLogo.imageset')
    os.makedirs(lg, exist_ok=True)
    logo(os.path.join(lg, 'LaunchLogo.png'))
    write_json(os.path.join(lg, 'Contents.json'), {
        'images': [{'filename': 'LaunchLogo.png', 'idiom': 'universal', 'scale': '1x'},
                   {'idiom': 'universal', 'scale': '2x'},
                   {'idiom': 'universal', 'scale': '3x'}],
        'info': {'author': 'xcode', 'version': 1}})
    print('[icon] Assets.xcassets 已生成：AppIcon / LaunchBackground / LaunchLogo')


if __name__ == '__main__':
    main()
