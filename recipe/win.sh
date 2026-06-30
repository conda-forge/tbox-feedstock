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
DEF_FILE="${BUILD_DIR}/tbox.def"

# The legacy configure/gmake generator does not apply the export-all rule from
# TBox's xmake.lua, producing a DLL with no exported symbols. Generate the
# module definition file from the compiled objects and relink the DLL.
#
# nm type letters map to .def entries as follows:
#   T, W           -> code symbol, exported by name
#   D, B, R, C, V  -> data symbol, exported with the DATA keyword so the import
#                     library references the variable itself rather than a thunk
# TBox has no public/internal naming convention, so every external tb_* symbol
# is exported — this matches upstream's xmake export-all rule.
{
    echo "EXPORTS"
    find "${OBJ_DIR}" -name '*.obj' -exec llvm-nm --defined-only --extern-only {} + \
        | awk '$3 ~ /^tb_/ {
                   if ($2 == "T" || $2 == "W") print $3;
                   else if ($2 ~ /^[DBRCV]$/) print $3 " DATA";
               }' \
        | sort -u
} > "${DEF_FILE}"

grep -qE '^tb_exit( DATA)?$' "${DEF_FILE}"
grep -qE '^tb_md5_init( DATA)?$' "${DEF_FILE}"
grep -qE '^tb_charset_conv_data( DATA)?$' "${DEF_FILE}"

sed -i "s|^tbox_shflags=|tbox_shflags= -Wl,/def:${DEF_FILE} |" Makefile
touch src/tbox/tbox.c
make tbox -j"${CPU_COUNT:-1}"

llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" | grep -q 'Name: tb_exit'
llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" | grep -q 'Name: tb_md5_init'
llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" | grep -q 'Name: tb_charset_conv_data'

install -Dm755 "${BUILD_DIR}/tbox.dll" "${PREFIX}/bin/tbox.dll"
install -Dm644 "${BUILD_DIR}/tbox.lib" "${PREFIX}/lib/tbox.lib"

mkdir -p "${PREFIX}/include"
cp -r src/tbox "${PREFIX}/include/"

install -Dm644 "${BUILD_DIR}/tbox.config.h" "${PREFIX}/include/tbox/tbox.config.h"
