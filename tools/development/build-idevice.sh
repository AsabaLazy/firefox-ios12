#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SUBMODULE_PATH="$REPO_ROOT/support/idevice"
FFI_DIR="$SUBMODULE_PATH/ffi"
OUTPUT_LIB="$REPO_ROOT/browser/Reynard/JIT/RPPairing/libidevice_ffi.a"

TARGET_DIR="$SUBMODULE_PATH/target"
DEPLOYMENT_TARGET="12.0"

if [ ! -e "$SUBMODULE_PATH/.git" ]; then
  git -C "$REPO_ROOT" submodule update --init --recursive support/idevice
fi

RUST_TARGET="aarch64-apple-ios"
DEPLOYMENT_FLAG="-miphoneos-version-min=${DEPLOYMENT_TARGET}"

if ! rustup target list | grep -q "^$RUST_TARGET (installed)"; then
	rustup target add "$RUST_TARGET"
fi

export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
if [ "$(uname -s)" != "Darwin" ]; then
  CACHE="${CHECK_CACHE:-$HOME/.cache/reynard-ios12-check}"
  SDK_VERSION="${SDK_VERSION:-26.5}"
  IOS_SDK_DIR="$CACHE/ios-sdks/iPhoneOS$SDK_VERSION.sdk"
  export PATH="$CACHE/bin:$HOME/.mozbuild/clang/bin:$PATH"
  export SDKROOT="$IOS_SDK_DIR"
  export CC_aarch64_apple_ios="clang"
  export CXX_aarch64_apple_ios="clang++"
  export AR_aarch64_apple_ios="llvm-ar"
  export CFLAGS_aarch64_apple_ios="--target=aarch64-apple-ios${DEPLOYMENT_TARGET} -isysroot $IOS_SDK_DIR"
  export CXXFLAGS_aarch64_apple_ios="--target=aarch64-apple-ios${DEPLOYMENT_TARGET} -isysroot $IOS_SDK_DIR"
fi
if [ -n "${RUSTFLAGS:-}" ]; then
  export RUSTFLAGS="${RUSTFLAGS} -C link-arg=${DEPLOYMENT_FLAG}"
else
  export RUSTFLAGS="-C link-arg=${DEPLOYMENT_FLAG}"
fi
export TARGET_DIR

mkdir -p "$(dirname "$OUTPUT_LIB")"
cd "$FFI_DIR"
cargo build --release --target "$RUST_TARGET" --no-default-features --features full,ring
cp "$TARGET_DIR/$RUST_TARGET/release/libidevice_ffi.a" "$OUTPUT_LIB"
