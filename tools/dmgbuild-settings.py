"""dmgbuild 配置：BrewPing Desktop 安装界面布局。

用法：dmgbuild -s tools/dmgbuild-settings.py "BrewPing Desktop" out.dmg
由 build-dmg.sh 调用（cd 到 BrewPing 项目根目录后执行，故用相对路径；
settings 由 dmgbuild exec 执行，没有 __file__ 变量）。
"""

# 卷名（Finder 标题栏显示）
volume_name = "BrewPing Desktop"

# 输出格式：压缩只读
format = "UDBZ"

# 文件来源
files = ["build/BrewPing Desktop.app"]
symlinks = {"Applications": "/Applications"}

# 背景图（dmgbuild 自动放进镜像内 .background/ 并写 .DS_Store）
background = "build/dmg-background.png"

# 窗口：((x, y), (w, h))，与背景图 660x400 一致
window_rect = ((200, 120), (660, 400))
icon_size = 72

# 图标位置（背景图布局：logo 在上方，两个图标在 y=290，箭头在中间）
icon_locations = {
    "BrewPing Desktop.app": (170, 290),
    "Applications": (490, 290),
    ".background": (620, 380),
}
