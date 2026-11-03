#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/engine/firefox"

TARGET="aarch64-apple-ios"
USE_SCCACHE=false
AUTO_CLOBBER=false
DISABLE_JEMALLOC=false

for arg in "$@"; do
	case "$arg" in
		--use-sccache)
			USE_SCCACHE=true
			;;
		--auto-clobber)
			AUTO_CLOBBER=true
			;;
		--disable-jemalloc)
			DISABLE_JEMALLOC=true
			;;
	esac
done

if [ "$USE_SCCACHE" = true ]; then
	SCCACHE_BIN="${SCCACHE_PATH:-$(command -v sccache)}"
fi

cd "$ROOT_DIR"

if [ ! -d "$FIREFOX_DIR" ]; then
	echo "Missing firefox source at $FIREFOX_DIR"
	echo "Add the submodule, then run tools/development/update-gecko.sh."
	exit 1
fi

# Apple clang cannot target wasm, which the RLBox sandboxed libraries need.
# Use the WASI SDK's self-consistent clang/linker/sysroot/builtins as the
# wasm toolchain, downloading it if not already present.
WASI_SDK_DIR="$SCRIPT_DIR/wasi-sdk"
WASI_SDK_ARCH="$(uname -m)"
if [ "$(uname -s)" = "Darwin" ]; then
	WASI_SDK_OS="macos"
else
	WASI_SDK_OS="linux"
fi
WASI_SDK_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/wasi-sdk-33.0-${WASI_SDK_ARCH}-${WASI_SDK_OS}.tar.gz"

if [ ! -d "$WASI_SDK_DIR" ]; then
	echo "Downloading WASI SDK ($WASI_SDK_ARCH-$WASI_SDK_OS)..."
	TMP_DIR="$(mktemp -d)"
	curl -L "$WASI_SDK_URL" -o "$TMP_DIR/wasi-sdk.tar.gz"
	mkdir -p "$WASI_SDK_DIR"
	tar -xzf "$TMP_DIR/wasi-sdk.tar.gz" -C "$WASI_SDK_DIR" --strip-components=1
	rm -rf "$TMP_DIR"
fi

# mozbuild clang ships no iOS compiler-rt, but our iOS 12 compat code uses
# @available(iOS 13, *) which clang lowers to __isPlatformVersionAtLeast.
# On macOS, link Xcode's libclang_rt.ios.a explicitly.
# On Linux, cross-compile using xybp888/iOS-SDKs + Mozilla's arm64 Darwin
# compiler-rt (re-tagged to PLATFORM_IOS minos 12.0) + an xcrun shim.
IOS_SDK_DIR=""
CLANG_RT_IOS=""
if [ "$(uname -s)" = "Darwin" ]; then
	DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
	for cand in "$DEV_DIR"/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a; do
		if [ -f "$cand" ]; then
			CLANG_RT_IOS="$cand"
			break
		fi
	done
	if [ -z "$CLANG_RT_IOS" ]; then
		echo "Warning: libclang_rt.ios.a not found under $DEV_DIR; XUL link may fail on __isPlatformVersionAtLeast" >&2
	fi
else
	CACHE="${CHECK_CACHE:-$HOME/.cache/reynard-ios12-check}"
	SDK_VERSION="${SDK_VERSION:-26.5}"
	SDK_REPO="$CACHE/ios-sdks"
	IOS_SDK_DIR="$SDK_REPO/iPhoneOS$SDK_VERSION.sdk"
	mkdir -p "$CACHE/bin" "$CACHE/darwin"
	if [ ! -d "$IOS_SDK_DIR/System" ]; then
		echo "Fetching iPhoneOS$SDK_VERSION.sdk for Linux cross-build..."
		rm -rf "$SDK_REPO"; git init -q "$SDK_REPO"
		git -C "$SDK_REPO" remote add origin https://github.com/xybp888/iOS-SDKs
		git -C "$SDK_REPO" fetch -q --depth 1 --filter=blob:none origin master
		git -C "$SDK_REPO" sparse-checkout set --no-cone "/iPhoneOS$SDK_VERSION.sdk/"
		git -C "$SDK_REPO" checkout -q FETCH_HEAD
	fi
	CLANG_RT_IOS="$CACHE/darwin/libclang_rt.ios.a"
	if [ ! -f "$CLANG_RT_IOS" ]; then
		echo "Preparing libclang_rt.ios.a (arm64, minos 12.0) from Mozilla Darwin compiler-rt..."
		TMP_CRT="$(mktemp -d)"
		curl -fsSL "https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.cache.level-3.toolchains.v3.macosx64-aarch64-compiler-rt-22.latest/artifacts/public/build/compiler-rt-aarch64-apple-darwin.tar.zst" \
			-o "$TMP_CRT/crt.tar.zst"
		tar --zstd -xf "$TMP_CRT/crt.tar.zst" -C "$TMP_CRT" compiler-rt-aarch64-apple-darwin/lib/darwin/libclang_rt.osx.a
		python3 - "$TMP_CRT/compiler-rt-aarch64-apple-darwin/lib/darwin/libclang_rt.osx.a" "$CLANG_RT_IOS" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    raw = f.read()
if raw[:4] == b"\xca\xfe\xba\xbe":
    _, _, offset, size, _ = struct.unpack(">IIIII", raw[8:28])
    data = bytearray(raw[offset:offset+size])
else:
    data = bytearray(raw)
pos = 0
while True:
    idx = data.find(b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01", pos)
    if idx == -1:
        break
    _, _, _, filetype, ncmds, _, _, _ = struct.unpack_from("<IIIIIIII", data, idx)
    if filetype == 1:
        cmd_off = idx + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, cmd_off)
            if cmd == 0x32:
                struct.pack_into("<II", data, cmd_off + 8, 2, 0x000c0000)
            cmd_off += cmdsize
    pos = idx + 32
with open(sys.argv[2], "wb") as f:
    f.write(data)
PY
		ln -sf "$CLANG_RT_IOS" "$CACHE/darwin/libclang_rt.iossim.a"
		rm -rf "$TMP_CRT"
	fi
	cat > "$CACHE/bin/xcrun" <<EOF
#!/bin/sh
for arg in "\$@"; do
	case "\$arg" in
		--show-sdk-path) echo "$IOS_SDK_DIR"; exit 0 ;;
		--show-sdk-version) echo "$SDK_VERSION"; exit 0 ;;
		-print-file-name=libclang_rt.ios.a) echo "$CLANG_RT_IOS"; exit 0 ;;
		-print-file-name=libclang_rt.iossim.a) echo "$CACHE/darwin/libclang_rt.iossim.a"; exit 0 ;;
	esac
done
while [ \$# -gt 0 ]; do
	case "\$1" in
		--sdk|-sdk) shift 2 ;;
		--find|-f) command -v "\$2"; exit \$? ;;
		*) break ;;
	esac
done
exec "\$@"
EOF
	chmod +x "$CACHE/bin/xcrun"
	cp "$CACHE/bin/xcrun" "$FIREFOX_DIR/build/macosx/xcrun"
	export PATH="$CACHE/bin:$HOME/.mozbuild/clang/bin:$PATH"
fi

if [ -f "$FIREFOX_DIR/.mozconfig" ]; then
	mv "$FIREFOX_DIR/.mozconfig" "$FIREFOX_DIR/.mozconfig.bak"
fi

{
	echo "ac_add_options --enable-application=mobile/ios"
	echo "ac_add_options --target=$TARGET"
	echo "ac_add_options --enable-ios-target=12.0"
	if [ -n "$IOS_SDK_DIR" ]; then
		echo "ac_add_options --with-ios-sdk=$IOS_SDK_DIR"
	fi
	echo "ac_add_options --enable-optimize"
	echo "ac_add_options --enable-release"
	echo "ac_add_options --enable-rust-simd"
	echo "ac_add_options --enable-lto"
	echo "ac_add_options --disable-debug"
	echo "export WASM_CC=$WASI_SDK_DIR/bin/clang"
	echo "export WASM_CXX=$WASI_SDK_DIR/bin/clang++"
	echo "ac_add_options --with-wasi-sysroot=$WASI_SDK_DIR/share/wasi-sysroot"
	if [ -n "$CLANG_RT_IOS" ]; then
		echo "export LDFLAGS=\"\$LDFLAGS $CLANG_RT_IOS\""
	fi
	echo "ac_add_options --disable-tests"
	echo "ac_add_options --enable-bootstrap"
	if [ "$USE_SCCACHE" = true ]; then
		echo "mk_add_options 'export RUSTC_WRAPPER=$SCCACHE_BIN'"
		echo "ac_add_options --with-ccache=$SCCACHE_BIN"
	fi
	if [ "$DISABLE_JEMALLOC" = true ]; then
		echo "ac_add_options --disable-jemalloc"
	fi
	if [ "$AUTO_CLOBBER" = true ]; then
		echo "mk_add_options AUTOCLOBBER=1"
	fi
} > "$FIREFOX_DIR/.mozconfig"

if ! rustup target list | grep -q "^$TARGET (installed)"; then
	rustup target add "$TARGET"
fi

cd "$FIREFOX_DIR"
./mach build

# Keep the generated mozconfig on disk (do NOT restore a stale backup):
# a leftover .mozconfig with an old --enable-ios-target makes any direct
# `./mach build` reconfigure the tree at the wrong deployment target
# (2026-09-20: merge rebuild via bare mach produced XUL minos 12.4 this way).
rm -f "$FIREFOX_DIR/.mozconfig.bak"

