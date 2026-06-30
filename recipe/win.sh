#!/bin/bash
set -euxo pipefail

cd "$SRC_DIR"

# Force clang toolchain for mingw platform detection
# configure hardcodes toolchains="x86_64_w64_mingw32" which probes for
# x86_64-w64-mingw32-gcc, but autotools_clang_conda provides clang/clang++
export CC=clang
export CXX=clang++
export CFLAGS="$CFLAGS -DNOCRYPT -DNOGDI"
export CXXFLAGS="$CXXFLAGS -DNOCRYPT -DNOGDI"
sed -i 's/toolchains="x86_64_w64_mingw32"/toolchains="clang"/' configure
# Add llvm-ar to clang toolchain's ar toolset (ar may not exist, but llvm-ar does)
sed -i '/^toolchain "clang"/,/^toolchain_end/{s/set_toolset "ar" "ar"/set_toolset "ar" "llvm-ar" "ar"/}' configure
# Add llvm-ar to path_toolname recognition
sed -i '/        ar) toolname="ar";;/a\        llvm-ar) toolname="ar";;' configure

# Remove pthread and m from mingw syslinks — they don't exist on MSVC target
# (math is in CRT, threading via Windows APIs; ws2_32 is still needed)
# user32 was added as accordinly to xmake.lua inside of root dir.
sed -i 's/add_syslinks "ws2_32" "pthread" "m"/add_syslinks "ws2_32" "user32"/' src/xmake.sh
# Do not append "lib" prefix to library names on Windows, as MSVC does not use it
sed -i 's/^[[:space:]]*prefixname="lib"/prefixname=""/' configure

./configure \
    --generator=gmake \
    --kind=shared \
    --hash=y \
    --charset=y \
    --prefix="${PREFIX}"

# Remove -fPIC from generated Makefile — unsupported on Windows MSVC target
sed -i 's/-fPIC//g' Makefile

make tbox -j"${CPU_COUNT:-1}"

BUILD_DIR="build/mingw/x86_64/release"
OBJ_DIR="build/.objs/tbox/mingw/x86_64/release"
RSP_FILE="${BUILD_DIR}/exports.rsp"

# The legacy configure/gmake generator does not apply TBox xmake's export-all
# rule, so the first link yields a DLL with no exported symbols. The linker is
# MSVC-style lld-link (despite the "mingw" platform name), so re-link with an
# explicit /EXPORT: directive per external tb_* symbol scraped from the objects,
# plus /implib to emit the COFF import library (tbox.lib). TBox has no
# public/internal naming convention, so every external tb_* symbol is exported,
# matching the export-all rule.
#
# Why /EXPORT: in a response file rather than a "/def:" flag:
#   * /EXPORT: entries are GC roots, so /OPT:REF (on by default in release) does
#     not dead-strip internally-unreferenced public functions (e.g. tb_md5_init,
#     which nothing inside tbox calls) before they can be exported — a bare def
#     dropped exactly those symbols.
#   * a response file's contents bypass the shell/MSYS leading-slash argv path
#     conversion that silently mangled a "/def:" flag on the command line.
#
# nm type letters: T/W -> code export; D/B/R/C/V -> data export (",DATA" so the
# import library references the variable itself rather than a code thunk).
{
    find "${OBJ_DIR}" -name '*.obj' -exec llvm-nm --defined-only --extern-only {} + \
        | awk '$3 ~ /^tb_/ {
                   if ($2 == "T" || $2 == "W") print "/EXPORT:" $3;
                   else if ($2 ~ /^[DBRCV]$/) print "/EXPORT:" $3 ",DATA";
               }' \
        | sort -u
    echo "/implib:${BUILD_DIR}/tbox.lib"
} > "${RSP_FILE}"

grep -qE '^/EXPORT:tb_exit(,DATA)?$' "${RSP_FILE}"
grep -qE '^/EXPORT:tb_md5_init(,DATA)?$' "${RSP_FILE}"
grep -qE '^/EXPORT:tb_charset_conv_data(,DATA)?$' "${RSP_FILE}"

sed -i "s|^tbox_shflags=|tbox_shflags= -Wl,@${RSP_FILE} |" Makefile
touch src/tbox/tbox.c
make tbox -j"${CPU_COUNT:-1}"

# Verify every requested symbol actually landed in the DLL export table; on
# failure list exactly what is missing so a regression is debuggable from the
# CI log alone.
llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" \
    | sed -n 's/^[[:space:]]*Name: //p' | sort -u > "${BUILD_DIR}/exports.actual"
sed -n 's|^/EXPORT:||p' "${RSP_FILE}" | sed 's/,DATA$//' | sort -u > "${BUILD_DIR}/exports.wanted"
missing="$(comm -23 "${BUILD_DIR}/exports.wanted" "${BUILD_DIR}/exports.actual")"
if [ -n "${missing}" ]; then
    echo "ERROR: $(printf '%s\n' "${missing}" | grep -c .) requested symbol(s) not exported from tbox.dll:" >&2
    printf '%s\n' "${missing}" | head -n 40 >&2
    exit 1
fi

# lld-link wrote the import library via /implib; confirm it references the
# exports. Run nm into a file so its exit status (it may warn on short-import
# members) cannot trip `set -o pipefail`, and match the thunk or __imp_ symbol.
test -f "${BUILD_DIR}/tbox.lib"
llvm-nm "${BUILD_DIR}/tbox.lib" > "${BUILD_DIR}/tbox.lib.syms" 2>&1 || true
if ! grep -q 'tb_exit' "${BUILD_DIR}/tbox.lib.syms"; then
    echo "ERROR: import library tbox.lib does not reference tb_exit" >&2
    ls -la "${BUILD_DIR}/tbox.lib" >&2
    echo "----- llvm-nm tbox.lib (head) -----" >&2
    head -n 40 "${BUILD_DIR}/tbox.lib.syms" >&2
    exit 1
fi

install -Dm755 "${BUILD_DIR}/tbox.dll" "${PREFIX}/bin/tbox.dll"
install -Dm644 "${BUILD_DIR}/tbox.lib" "${PREFIX}/lib/tbox.lib"

mkdir -p "${PREFIX}/include"
cp -r src/tbox "${PREFIX}/include/"

install -Dm644 "${BUILD_DIR}/tbox.config.h" "${PREFIX}/include/tbox/tbox.config.h"
