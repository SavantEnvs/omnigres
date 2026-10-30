#!/usr/bin/env bash
#
# mayhem/pg-build.sh — Dockerfile-time step (needs the network, runs once, before the repo is COPYed in).
#
# omnigres' extensions are PostgreSQL extensions: their C code calls the PostgreSQL backend (parser,
# memory contexts, fmgr, ...). To fuzz that code in-process we link it against a sanitized copy of the
# PostgreSQL 17 backend. This script builds the backend objects once and leaves them, as a static
# archive that has no main(), under /opt/toolchains/pg so that the air-gapped, re-runnable
# mayhem/build.sh only has to compile omnigres' own sources and link.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

PGVER=17.6
PGSHA=e0630a3600aea27511715563259ec2111cd5f4353a4b040e0be827f94cd7a8b0   # sha256 of postgresql-17.6.tar.bz2
PREFIX=/opt/toolchains/pg
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"

# PostgreSQL's own code carries benign UB that UBSan would flag, so the backend gets ASan only (omnigres'
# code, built by build.sh, gets the full SANITIZER_FLAGS). With an explicit empty SANITIZER_FLAGS nothing is
# instrumented, so the libFuzzer coverage hooks are left out too (they need a runtime to link).
PG_SAN="$(printf '%s' "$SANITIZER_FLAGS" | sed -E 's/(=|,)undefined,/\1/; s/,undefined//; s/(^| )-g[0-9a-z-]*( |$)/ /g')"
PG_COV=""
[ -z "$SANITIZER_FLAGS" ] || PG_COV="-fsanitize=fuzzer-no-link"
# PostgreSQL's check_stack_depth() compares frame addresses: with ASan's default fake stack for
# use-after-return its frames sit on the heap and every deeply recursive statement would be rejected.
case "$PG_SAN" in *address*) PG_SAN="$PG_SAN -fsanitize-address-use-after-return=never" ;; esac
# PostgreSQL itself is not the code under test: function names and line tables are enough for its frames.
PG_DEBUG="-g1 -gdwarf-3"
# A release-style backend (no --enable-cassert): omnigres' deparser is full of `Assert(false)` for node types
# it does not handle, which a production server compiles out, so cassert would turn those into noise. Keep
# the one cassert feature ASan cannot replace: palloc'd chunks get a sentinel byte that is checked on free.
# It changes struct layouts in the headers, so build.sh compiles omnigres' code with the same define.
PG_DEFS="-DMEMORY_CONTEXT_CHECKING"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
curl -fsSL --retry 5 -o "$W/pg.tar.bz2" "https://ftp.postgresql.org/pub/source/v$PGVER/postgresql-$PGVER.tar.bz2"
echo "$PGSHA  $W/pg.tar.bz2" | sha256sum -c -
tar -C "$W" -xjf "$W/pg.tar.bz2"
cd "$W/postgresql-$PGVER"

export ASAN_OPTIONS=detect_leaks=0
./configure --prefix="$PREFIX" --without-icu --without-readline --without-zlib --without-openssl \
  CC="$CC" CFLAGS="-O1 $PG_DEFS $PG_SAN $PG_COV $PG_DEBUG" LDFLAGS="$PG_SAN"

# Sequential at the library level: parallel make races on the generated headers and on libpgcommon's shlib.
make -C src/backend generated-headers
make -C src/port libpgport_srv.a
make -C src/common libpgcommon_srv.a
make -C src/timezone -j"$MAYHEM_JOBS"
make -C src/backend -j"$MAYHEM_JOBS"
make -C src/include install

mkdir -p "$PREFIX/lib"
cat src/backend/*/objfiles.txt src/timezone/objfiles.txt | tr ' ' '\n' | grep '\.o$' \
  | grep -v '^src/backend/main/main\.o$' | sort -u > "$W/objs.txt"
ar crs "$PREFIX/lib/libpgbackend.a" $(cat "$W/objs.txt")
cp src/port/libpgport_srv.a src/common/libpgcommon_srv.a "$PREFIX/lib/"
printf '%s\n' "$PG_SAN" > "$PREFIX/sanitizer.flags"
printf '%s\n' "$PG_COV" > "$PREFIX/coverage.flags"
printf '%s\n' "$PG_DEFS" > "$PREFIX/defines.flags"
chmod -R a+rX "$PREFIX"
