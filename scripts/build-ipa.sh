#!/bin/bash
# Build the Madeira .ipa from a fresh clone on macOS (CI / developer laptop).
#
# Reproduces the full willfaust/Madeira toolchain: llvm-mingw, LLVM 15 for
# iOS, GnuTLS stack, FreeType, Wine build-macos, the iOS wine unix libs,
# FEX build-ios, DXMT, then xcodebuild -> Payload/Madeira.app zip.
#
# Each stage writes build/logs/<stage>.log; on failure the tail is printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
LOG_DIR="$REPO_ROOT/build/logs"
mkdir -p "$LOG_DIR"

HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$HOMEBREW_PREFIX/opt/bison/bin:$PATH"
export PATH="$HOMEBREW_PREFIX/opt/flex/bin:$PATH"
export PATH="$HOMEBREW_PREFIX/opt/llvm/bin:$PATH"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
LLVM_MINGW="toolchains/llvm-mingw-20260421-ucrt-macos-universal"
LLVM_PROJECT="toolchains/llvm-project"
LLVM_IOS="toolchains/llvm-ios-build"

log_tail() { # <logfile>
    if [ -f "$1" ]; then
        echo "--- tail of $1 ---"
        tail -n 60 "$1" || true
    fi
}

run_stage() { # <name> <func...>
    local name="$1"; shift
    local log="$LOG_DIR/$name.log"
    echo ""
    echo "==== STAGE $name ===="
    if "$@" >"$log" 2>&1; then
        echo "STAGE $name: OK"
    else
        echo "STAGE $name: FAILED"
        log_tail "$log"
        exit 1
    fi
}

download() { # <url> <dest>
    local url="$1" dest="$2"
    for i in 1 2 3; do
        if curl -fSL --retry 3 --connect-timeout 30 "$url" -o "$dest.tmp"; then
            mv "$dest.tmp" "$dest"
            return 0
        fi
        echo "download failed (attempt $i): $url" >&2
        sleep 5
    done
    return 1
}

stage_toolchains() {
    mkdir -p toolchains
    download "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz" \
        "$LOG_DIR/llvm-mingw.tar.xz"
    tar -xJf "$LOG_DIR/llvm-mingw.tar.xz" -C toolchains/
    test -x "$REPO_ROOT/$LLVM_MINGW/bin/aarch64-w64-mingw32-clang"
}

stage_llvm() {
    mkdir -p toolchains
    curl -fL --retry 3 -o "$LOG_DIR/llvm-15.tar.gz" \
        "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-15.0.7.tar.gz"
    tar -xzf "$LOG_DIR/llvm-15.tar.gz" -C toolchains/
    mv "$(ls -d toolchains/llvm-project-* | head -1)" "$LLVM_PROJECT"

    # Apple ld only accepts -dead_strip; iOS registers as "iOS" not "Darwin",
    # so widen the match or the LLVM libs get linked with --gc-sections.
    sed -i '' 's/CMAKE_SYSTEM_NAME} MATCHES "Darwin"/CMAKE_SYSTEM_NAME} MATCHES "Darwin|iOS"/g' \
        "$LLVM_PROJECT/llvm/cmake/modules/AddLLVM.cmake"

    cmake -S "$LLVM_PROJECT/llvm" -B toolchains/llvm-host-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_BUILD_TOOLS=ON -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
    cmake --build toolchains/llvm-host-build --target llvm-tblgen -j "$JOBS"

    cmake -S "$LLVM_PROJECT/llvm" -B "$LLVM_IOS" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_C_COMPILER="$(xcrun -f clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_TABLEGEN="$REPO_ROOT/toolchains/llvm-host-build/bin/llvm-tblgen" \
        -DLLVM_TARGETS_TO_BUILD="AArch64;ARM" \
        -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_FFI=OFF
    cmake --build "$LLVM_IOS" -j "$JOBS"
    test -f "$LLVM_IOS/lib/libLLVMCore.a"
}

stage_gnutls() {
    mkdir -p build/gnutls-ios/src
    download "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz" \
        "build/gnutls-ios/src/gmp-6.3.0.tar.xz"
    download "https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz" \
        "build/gnutls-ios/src/nettle-3.10.1.tar.gz"
    download "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.9.tar.xz" \
        "build/gnutls-ios/src/gnutls-3.8.9.tar.xz" || \
        download "https://ftp.gnu.org/gnu/gnutls/v3.8/gnutls-3.8.9.tar.xz" \
        "build/gnutls-ios/src/gnutls-3.8.9.tar.xz"

    JOBS="$JOBS" bash build/gnutls-ios/build.sh
    mkdir -p app/Madeira
    cp toolchains/gnutls-ios/lib/libgmp.a \
       toolchains/gnutls-ios/lib/libnettle.a \
       toolchains/gnutls-ios/lib/libhogweed.a \
       toolchains/gnutls-ios/lib/libgnutls.a \
       app/Madeira/
}

stage_freetype() {
    FT_VER=2.13.3
    FT_DIR="build/freetype-ios/src/freetype-$FT_VER"
    mkdir -p "build/freetype-ios/src"
    download "https://download.savannah.gnu.org/releases/freetype/freetype-$FT_VER.tar.gz" \
        "$LOG_DIR/freetype-$FT_VER.tar.gz"
    tar -xzf "$LOG_DIR/freetype-$FT_VER.tar.gz" -C "build/freetype-ios/src"

    cmake -S "$FT_DIR" -B "build/freetype-ios/build-obj" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_INSTALL_PREFIX="$REPO_ROOT/build/freetype-ios/build" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_ZLIB=ON
    cmake --build "build/freetype-ios/build-obj" -j "$JOBS"
    cmake --install "build/freetype-ios/build-obj"

    # Wine includes <freetype/freetype.h> with ft2build.h at the include root;
    # cmake installs the tree under include/freetype2, so alias it.
    ln -sfn freetype2/freetype "build/freetype-ios/build/include/freetype"
    mkdir -p research
    mkdir -p research/freetype
    ln -sfn ../build/freetype-ios/src/freetype-$FT_VER/include research/freetype/include
    test -f "build/freetype-ios/build/lib/libfreetype.a"
}

stage_wine() {
    test -d wine/dlls
    mkdir -p wine/build-macos
    (
        cd wine/build-macos
        ../configure \
            --without-mingw --without-x --without-freetype --without-vulkan \
            --without-gstreamer --without-cups --without-oss --without-alsa \
            --without-gphoto --without-usb --without-v4l2 --without-opencl \
            --without-dbus --without-sane --without-gssapi --without-pulse \
            --disable-tests --disable-win16 --disable-compat16 \
            CC=clang CXX=clang++
    )
    make -C wine/build-macos -j "$JOBS"

    # widl-generated headers (dwrite.h etc.) land in build-macos/include; the
    # ntdll build.sh looks in build-arm64ec/include for them.
    mkdir -p wine/build-arm64ec
    ln -sfn ../build-macos/include wine/build-arm64ec/include

    test -f wine/build-macos/include/config.h
    test -f wine/build-macos/server/libwineserver.a
    mkdir -p app/Madeira
    cp wine/build-macos/server/libwineserver.a app/Madeira/libwineserver.a
}

stage_wine_unix_libs() {
    bash build/ntdll-unix/build.sh
    bash build/wineserver/build.sh all
    bash build/win32u-unix/build.sh
}

stage_fex() {
    for sub in fmt xxhash unordered_dense range-v3; do
        test -d "FEX/External/$sub" || { echo "missing FEX submodule External/$sub"; exit 1; }
    done
    cmake -S FEX -B FEX/build-ios -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_C_COMPILER="$(xcrun -f clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DENABLE_CCACHE=OFF -DENABLE_LTO=OFF -DENABLE_ASSERTIONS=OFF \
        -DENABLE_WERROR=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_TESTING=OFF \
        -DBUILD_FEX_LINUX_TESTS=OFF
    cmake --build FEX/build-ios -j "$JOBS" \
        --target fmt xxhash cephes_128bit softfloat_3e JemallocLibs FEXCore_Base FEXCore
    test -f FEX/build-ios/FEXCore/Source/libFEXCore.a
    test -f FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
    test -f FEX/build-ios/FEXCore/Source/libJemallocLibs.a
    test -f FEX/build-ios/External/fmt/libfmt.a
    test -f FEX/build-ios/External/cephes/libcephes_128bit.a
    test -f FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a
    test -f FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a
}

stage_dxmt() {
    mkdir -p build/dxmt-ios/shader-headers
    bash build/dxmt-ios/build.sh
    xcrun -sdk iphoneos libtool -static -o build/dxmt-ios/libdxmt_combined.a \
        build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
    mkdir -p app/Madeira
    cp build/dxmt-ios/libdxmt_combined.a app/Madeira/libdxmt_combined.a
    test -f app/Madeira/libdxmt_combined.a
}

stage_app() {
    rm -rf build/xcode-derived "build/derived-data"
    xcrun xcodebuild \
        -project app/Madeira.xcodeproj \
        -target Madeira \
        -configuration Release \
        -sdk iphoneos \
        -derivedDataPath build/xcode-derived \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        ONLY_ACTIVE_ARCH=YES \
        PRODUCT_BUNDLE_IDENTIFIER=com.madeira.emulator \
        build
    APP="$REPO_ROOT/build/xcode-derived/Build/Products/Release-iphoneos/Madeira.app"
    test -x "$APP/Madeira"
    echo "APP_PATH=$APP"
}

stage_ipa() {
    local ver="${VERSION:-$(date +%Y.%m.%d)}"
    local app="$REPO_ROOT/build/xcode-derived/Build/Products/Release-iphoneos/Madeira.app"
    test -d "$app"
    rm -rf "$REPO_ROOT/Payload" "$REPO_ROOT/dist"
    mkdir -p "$REPO_ROOT/Payload" "$REPO_ROOT/dist"
    cp -R "$app" "$REPO_ROOT/Payload/Madeira.app"
    (
        cd "$REPO_ROOT/Payload"
        zip -qry "$REPO_ROOT/dist/Madeira-$ver.ipa" Madeira.app
    )
    cp "$REPO_ROOT/dist/Madeira-$ver.ipa" "$REPO_ROOT/dist/Madeira.ipa"
    (cd "$REPO_ROOT/dist" && shasum -a 256 Madeira-$ver.ipa > SHA256SUMS)
    echo "IPA=$REPO_ROOT/dist/Madeira-$ver.ipa"
    du -sh "$REPO_ROOT/dist/Madeira-$ver.ipa"
}

STAGE="${1:-all}"
case "$STAGE" in
    all)
        run_stage toolchains stage_toolchains
        run_stage llvm stage_llvm
        run_stage gnutls stage_gnutls
        run_stage freetype stage_freetype
        run_stage wine stage_wine
        run_stage wine-unix-libs stage_wine_unix_libs
        run_stage fex stage_fex
        run_stage dxmt stage_dxmt
        run_stage app stage_app
        run_stage ipa stage_ipa
        ;;
    toolchains|llvm|gnutls|freetype|wine|fex|dxmt|app|ipa)
        run_stage "$STAGE" "stage_$STAGE"
        ;;
    wine-unix-libs)
        run_stage wine-unix-libs stage_wine_unix_libs
        ;;
    *)
        echo "usage: $0 [all|toolchains|llvm|gnutls|freetype|wine|wine-unix-libs|fex|dxmt|app|ipa]"
        exit 1
        ;;
esac
echo ""
echo "BUILD COMPLETE"