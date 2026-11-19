#!/bin/zsh
# 用法：./build.sh            构建到 build/
#       ./build.sh install    构建并安装到 /Applications，重启正在运行的实例
set -euo pipefail
cd -- "${0:A:h}"

name='islet'
app="build/$name.app"
min_macos='14.0'   # NSApp.activate() 需要 macOS 14

# 目录：Sources/ 主程序源码（按模块分子目录，整个目录一起编译）；Helpers/ 独立的辅助程序；Resources/ 打包进 .app 的资源
# 图标缺失时用 make-icon.swift 重新生成
if [[ ! -f Resources/islet.icns ]]; then
    iconset="$(mktemp -d)/islet.iconset"
    mkdir -p "$iconset"
    swift Resources/make-icon.swift "$iconset"
    iconutil -c icns "$iconset" -o Resources/islet.icns
fi

rm -rf "$app"
helper_dir="$app/Contents/Library/FanHelper"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper_dir"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/islet.icns "$app/Contents/Resources/islet.icns"
cp docs/donate/alipay.png docs/donate/wechat.png "$app/Contents/Resources/"   # 关于页的打赏二维码

# 主程序源码：Sources 下全部 .swift（新增文件放进去即可，不用改这里）
sources=(Sources/**/*.swift)
# 风扇控制辅助程序和主程序共用 SMC、风扇控制两个文件
fan_shared=(Sources/Metrics/SMC.swift Sources/Fan/FanControl.swift)

# 通用二进制（Apple 芯片 + Intel）
for arch in arm64 x86_64; do
    swiftc -O -whole-module-optimization -target "$arch-apple-macos$min_macos" \
        -import-objc-header Sources/Bridging.h \
        "${sources[@]}" \
        -o "build/islet-$arch"
    # 风扇控制辅助程序（以 root 运行，安装时复制到 /Library/PrivilegedHelperTools）
    swiftc -O -whole-module-optimization -target "$arch-apple-macos$min_macos" \
        -import-objc-header Sources/Bridging.h \
        "${fan_shared[@]}" Helpers/FanHelper/main.swift \
        -o "build/FanHelper-$arch"
    swiftc -O -target "$arch-apple-macos$min_macos" Helpers/display-helper.swift -o "build/islet-display-$arch"
done
lipo -create build/islet-arm64 build/islet-x86_64 -output "$app/Contents/MacOS/islet"
lipo -create build/FanHelper-arm64 build/FanHelper-x86_64 -output "$helper_dir/isletFanHelper"
lipo -create build/islet-display-arm64 build/islet-display-x86_64 -output "$app/Contents/MacOS/islet-display"
codesign --force --sign - "$app/Contents/MacOS/islet-display"
rm -f build/islet-arm64 build/islet-x86_64 build/FanHelper-arm64 build/FanHelper-x86_64 build/islet-display-arm64 build/islet-display-x86_64
cp Helpers/FanHelper/launchd.plist "$helper_dir/local.codex.islet.fanhelper.plist"
codesign --force --sign - --identifier local.codex.islet.fanhelper "$helper_dir/isletFanHelper"
# 正在播放读取组件：由系统 /usr/bin/perl 加载（第三方程序无法直接读取正在播放的信息）
clang -dynamiclib -fobjc-arc -framework Foundation -arch arm64 -arch x86_64 -mmacosx-version-min=$min_macos \
    Helpers/NowPlayingAdapter.m -o "$app/Contents/Resources/NowPlayingAdapter.dylib"
codesign --force --sign - "$app/Contents/Resources/NowPlayingAdapter.dylib"

# 主程序用钥匙串里的本地签名证书签名：签名稳定，屏幕录制、系统录音、蓝牙等权限授权一次就够；
# 证书叫“islet 本地签名”或改名前的“系统监控 本地签名”都可以。
# 都没有时退回临时签名（每次构建后需要重新授权）
identity=$(security find-identity -p codesigning 2>/dev/null | awk '/islet 本地签名|系统监控 本地签名/ { print $2; exit }')
if [ -n "$identity" ]; then
    codesign --force --sign "$identity" --identifier local.codex.islet "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "已构建：$app"

if [[ "${1:-}" == install ]]; then
    if pkill -x islet 2>/dev/null || pkill -x SpeedBar 2>/dev/null; then sleep 0.5; fi
    rm -rf "/Applications/$name.app"
    cp -R "$app" /Applications/
    open "/Applications/$name.app"
    echo "已安装并启动：/Applications/$name.app"
fi
