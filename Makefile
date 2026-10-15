# BatteryScope build entry points.
#
# Every target below goes through Scripts/resolve-sdk.sh, because a bare `swift build` picks
# the default macOS SDK whose SwiftUI declares @State as a macro from an Xcode-only plugin.
# See README.md ("为什么不能用默认 SDK") for the details.

SDK := $(shell Scripts/resolve-sdk.sh 2>/dev/null)
export SDKROOT := $(SDK)

.DEFAULT_GOAL := app

.PHONY: help sdk build app cli test run stop dmg clean distclean install uninstall

help:
	@echo "make sdk       — 显示当前会使用的 macOS SDK"
	@echo "make build     — 只编译（debug）"
	@echo "make app       — 编译并打包 dist/BatteryScope.app（release）"
	@echo "make cli       — 编译命令行工具"
	@echo "make test      — 运行内置自检（139 项断言）"
	@echo "make dmg       — 打包成 dmg 放到 ~/Downloads（可传 OUT= 指定目录）"
	@echo "make run       — 打包并启动应用"
	@echo "make stop      — 退出正在运行的 BatteryScope"
	@echo "make install   — 安装到 /Applications 并启动"
	@echo "make clean     — 删除构建产物"
	@echo "make distclean — 删除构建产物与 dist"

sdk:
	@echo "$(SDK)"

build:
	@test -n "$(SDK)" || { echo "找不到可用的 SDK"; exit 1; }
	swift build

app:
	Scripts/build-app.sh release

cli:
	@test -n "$(SDK)" || { echo "找不到可用的 SDK"; exit 1; }
	swift build -c release --product batteryscope-cli
	@echo "dist 中的命令行工具由 make app 一并产出；本地可执行文件在 .build/release/batteryscope-cli"

test:
	@test -n "$(SDK)" || { echo "找不到可用的 SDK"; exit 1; }
	swift build --product batteryscope-cli
	./.build/debug/batteryscope-cli selftest

dmg: app
	Scripts/build-dmg.sh $(OUT)

run: app
	open dist/BatteryScope.app

stop:
	@pkill -x BatteryScope 2>/dev/null && echo "已退出 BatteryScope" || echo "BatteryScope 未在运行"

clean:
	rm -rf .build

distclean: clean
	rm -rf dist
