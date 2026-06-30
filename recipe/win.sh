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

# The linker is MSVC-style lld-link (despite the "mingw" platform name), so the
# module-definition file must be passed with the "/def:" flag — a positional
# .def is rejected as "unknown file type". Passing "/def:..." directly on the
# command line is unreliable here: the leading-slash argument is mangled before
# lld-link sees it, so the DLL links with no exports and no error. Put the flag
# in a linker response file instead (its contents bypass shell/argv path
# conversion) and reference it with the slash-free "@file" form.
RSP_FILE="${BUILD_DIR}/exports.rsp"
printf '/def:%s\n' "${DEF_FILE}" > "${RSP_FILE}"
sed -i "s|^tbox_shflags=|tbox_shflags= -Wl,@${RSP_FILE} |" Makefile
touch src/tbox/tbox.c
make tbox -j"${CPU_COUNT:-1}"

# Verify the relinked DLL actually exports the symbols; dump diagnostics on
# failure so a regression here is debuggable from the CI log alone.
for sym in tb_exit tb_md5_init tb_charset_conv_data; do
    if ! llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" | grep -qE "Name: ${sym}$"; then
        echo "ERROR: '${sym}' is not exported from tbox.dll after relink" >&2
        echo "----- ${DEF_FILE} (head) -----" >&2
        head -n 20 "${DEF_FILE}" >&2
        echo "----- tbox.dll exports (head) -----" >&2
        llvm-readobj --coff-exports "${BUILD_DIR}/tbox.dll" 2>&1 | head -n 40 >&2
        exit 1
    fi
done

# Generate the import library explicitly from the def so the package ships a
# COFF tbox.lib (no .dll.a) regardless of the driver's default implib name and
# location. llvm-dlltool honors the def's DATA entries, so data exports import
# as data (__imp_ only) rather than through a code thunk.
llvm-dlltool -m i386:x86-64 -d "${DEF_FILE}" -D tbox.dll -l "${BUILD_DIR}/tbox.lib"
llvm-nm "${BUILD_DIR}/tbox.lib" | grep -q '__imp_tb_exit'

install -Dm755 "${BUILD_DIR}/tbox.dll" "${PREFIX}/bin/tbox.dll"
install -Dm644 "${BUILD_DIR}/tbox.lib" "${PREFIX}/lib/tbox.lib"

mkdir -p "${PREFIX}/include"
cp -r src/tbox "${PREFIX}/include/"

install -Dm644 "${BUILD_DIR}/tbox.config.h" "${PREFIX}/include/tbox/tbox.config.h"
