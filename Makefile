# Prefer a full Xcode toolchain: SwiftUI macros are unavailable in a bare
# Command Line Tools installation.
XCODE := $(shell for d in /Applications/Xcode*.app/Contents/Developer; do [ -d "$$d" ] && echo "$$d" && break; done)
export DEVELOPER_DIR := $(if $(XCODE),$(XCODE),$(shell xcode-select -p))

CLI := .build/out/Products/Release/ventoymac-cli
APP := dist/VentoyMac.app

# SwiftPM's manifest sandbox cannot be applied inside a nested sandbox
# ("sandbox-exec: sandbox_apply: Operation not permitted"). This package has
# no external dependencies, so disabling the manifest sandbox is harmless.
SWIFT_FLAGS := --disable-sandbox

.DEFAULT_GOAL := app

.PHONY: build debug test selftest app run clean help assets import

build:
	swift build $(SWIFT_FLAGS) -c release --arch arm64

debug:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

selftest: build
	$(CLI) self-test

assets: build
	$(CLI) assets

import: build
	@test -n "$(PKG)" || { echo "用法: make import PKG=/路径/ventoy-1.1.18-linux.tar.gz [SHA256=<官方摘要>]"; exit 2; }
	$(CLI) import-assets $(PKG) $(SHA256)

app: build
	@chmod +x Scripts/make_app.sh
	@bash Scripts/make_app.sh

run: app
	open $(APP)

clean:
	swift package clean
	rm -rf dist

help:
	@echo "VentoyMac 构建目标"
	@echo "  make build      Release 编译（arm64）"
	@echo "  make test       XCTest 单元测试（需完整 Xcode）"
	@echo "  make selftest   CLI 自检（无需 Xcode / 无需 U 盘）"
	@echo "  make assets     查看已缓存引导资源与校验结果"
	@echo "  make import PKG=<tar.gz> [SHA256=<摘要>]   离线导入官方发布包"
	@echo "  make app        生成 dist/VentoyMac.app"
	@echo "  make run        构建并打开应用"
	@echo "  make clean      清理构建产物"
	@echo ""
	@echo "当前工具链: $(DEVELOPER_DIR)"
