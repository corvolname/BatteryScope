#!/bin/bash
# Resolves the macOS SDK this project must be built against.
#
# Why this is necessary: the macOS 27 SDK declares SwiftUI's `@State` (and friends) as a
# macro backed by the `SwiftUIMacros` compiler plugin. That plugin only ships inside Xcode.
# With a Command Line Tools toolchain every SwiftUI view therefore fails with:
#
#     external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
#
# So we pick the newest installed SDK whose SwiftUI still declares `@State` as an ordinary
# property wrapper. Override with BATTERYSCOPE_SDK=/path/to/MacOSX.sdk.
set -euo pipefail

if [ -n "${BATTERYSCOPE_SDK:-}" ]; then
    printf '%s\n' "$BATTERYSCOPE_SDK"
    exit 0
fi

root="/Library/Developer/CommandLineTools/SDKs"
[ -d "$root" ] || { echo "找不到 SDK 目录 $root" >&2; exit 1; }

# `MacOSX.sdk` is a symlink to the default; skip it so we enumerate concrete versions.
candidates=$(ls -d "$root"/MacOSX*.sdk 2>/dev/null | grep -v '/MacOSX\.sdk$' || true)
[ -n "$candidates" ] || { echo "在 $root 下没有找到任何 MacOSX*.sdk" >&2; exit 1; }

ordered=$(printf '%s\n' $candidates | sort -Vr 2>/dev/null || printf '%s\n' $candidates | sort -r)

for sdk in $ordered; do
    interface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    [ -f "$interface" ] || continue
    # `struct State<` present AND no `macro State` => property wrapper, not a macro.
    if grep -q 'struct State<' "$interface" && ! grep -q 'macro State' "$interface"; then
        printf '%s\n' "$sdk"
        exit 0
    fi
done

echo "没有找到 SwiftUI 仍以属性包装器定义 @State 的 SDK；请安装 Xcode 或设置 BATTERYSCOPE_SDK" >&2
exit 1
