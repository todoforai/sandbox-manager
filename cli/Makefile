ZIGCC ?= zig cc
OPTFLAGS ?= -Oz -ffunction-sections -fdata-sections -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident
LDFLAGS ?= -Wl,--gc-sections -Wl,--build-id=none
WARNFLAGS ?= -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wno-unused-function
CFLAGS ?= $(OPTFLAGS) $(WARNFLAGS) -I../../todoforai-c-core/noise -I../../todoforai-c-core/cli -I../../todoforai-c-core/login
SRCS = main.c ../../todoforai-c-core/noise/noise.c ../../todoforai-c-core/noise/vendor/blake2s.c ../../todoforai-c-core/noise/vendor/monocypher.c
STRIP ?= strip --strip-all -R .comment -R .note -R .eh_frame

TARGETS = \
	build/sandbox-linux-x86_64 \
	build/sandbox-linux-aarch64 \
	build/sandbox-macos-x86_64 \
	build/sandbox-macos-aarch64 \
	build/sandbox-windows-x86_64.exe

.PHONY: all linux macos windows clean

all: $(TARGETS)

linux: build/sandbox-linux-x86_64 build/sandbox-linux-aarch64
macos: build/sandbox-macos-x86_64 build/sandbox-macos-aarch64
windows: build/sandbox-windows-x86_64.exe

build/sandbox-linux-x86_64: $(SRCS) ../../todoforai-c-core/noise/noise.h | build
	$(ZIGCC) $(CFLAGS) $(LDFLAGS) -target x86_64-linux-musl -o $@ $(SRCS)
	$(STRIP) $@ 2>/dev/null || true

build/sandbox-linux-aarch64: $(SRCS) ../../todoforai-c-core/noise/noise.h | build
	$(ZIGCC) $(CFLAGS) $(LDFLAGS) -target aarch64-linux-musl -o $@ $(SRCS)
	$(STRIP) $@ 2>/dev/null || true

build/sandbox-macos-x86_64: $(SRCS) ../../todoforai-c-core/noise/noise.h | build
	$(ZIGCC) $(CFLAGS) $(LDFLAGS) -target x86_64-macos -o $@ $(SRCS)
	$(STRIP) $@ 2>/dev/null || true

build/sandbox-macos-aarch64: $(SRCS) ../../todoforai-c-core/noise/noise.h | build
	$(ZIGCC) $(CFLAGS) $(LDFLAGS) -target aarch64-macos -o $@ $(SRCS)
	$(STRIP) $@ 2>/dev/null || true

build/sandbox-windows-x86_64.exe: $(SRCS) ../../todoforai-c-core/noise/noise.h | build
	$(ZIGCC) $(CFLAGS) $(LDFLAGS) -target x86_64-windows-gnu -lws2_32 -ladvapi32 -o $@ $(SRCS)
	$(STRIP) $@ 2>/dev/null || true

build:
	mkdir -p build

clean:
	rm -rf build
