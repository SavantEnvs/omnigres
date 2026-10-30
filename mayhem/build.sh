#!/usr/bin/env bash
#
# mayhem/build.sh — build the omnigres fuzz harnesses (and the known-answer probe test.sh drives).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem, offline, and is re-runnable.
# omnigres' extensions are PostgreSQL extensions; their C code is compiled here, from this tree, and linked
# against a sanitized PostgreSQL 17 backend archive that mayhem/pg-build.sh left in /opt/toolchains/pg
# (the Dockerfile builds it once, with the network, before the source is copied in).
#
# Outputs, all in /mayhem:  fuzz_<target> and fuzz_<target>-standalone for each target, and mayhem-kat.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

PGP=/opt/toolchains/pg
for f in lib/libpgbackend.a lib/libpgcommon_srv.a lib/libpgport_srv.a include/postgresql/server/postgres.h; do
  [ -f "$PGP/$f" ] || { echo "build.sh: $PGP/$f is missing (mayhem/pg-build.sh runs from mayhem/Dockerfile)" >&2; exit 1; }
done
PG_SAN="$(cat "$PGP/sanitizer.flags")"
PG_COV="$(cat "$PGP/coverage.flags")"
PG_INC="-I$PGP/include/postgresql/server -I$PGP/include -D_GNU_SOURCE $(cat "$PGP/defines.flags")"
PG_LIBS="-Wl,--start-group $PGP/lib/libpgbackend.a $PGP/lib/libpgcommon_srv.a $PGP/lib/libpgport_srv.a -Wl,--end-group -lm -lpthread -ldl -lrt"

OMNI_SQL=extensions/omni_sql
OMNI_WEB=extensions/omni_web
ADA=deps/ada_url
SQL_SRCS="$OMNI_SQL/deparse.c $OMNI_SQL/deparse_13.c $OMNI_SQL/deparse_14.c $OMNI_SQL/deparse_15.c
          $OMNI_SQL/deparse_16.c $OMNI_SQL/deparse_17.c $OMNI_SQL/deparse_18.c $OMNI_SQL/deparse_19.c
          $OMNI_SQL/lib.c"

# Two independent builds of everything: "san" (sanitizers + coverage + DWARF 3, for the fuzzers) and
# "plain" (the project's normal flags, for the known-answer probe). Both live under the gitignored
# mayhem/.build so a `git clean -ffdX` starts them from scratch.
B="$SRC/mayhem/.build"
mkdir -p "$B"

CFLAGS_san="-O1 $SANITIZER_FLAGS ${SANITIZER_FLAGS:+-fsanitize=fuzzer-no-link} $DEBUG_FLAGS"
CFLAGS_plain="-O2 $COVERAGE_FLAGS"

# --- third-party code vendored in deps/: pcre2 (ada's regex provider) and uriparser (omni_web) ---
# The compiler comes from the exported $CC, not -DCMAKE_C_COMPILER: CMake compares that flag with the
# cached absolute path on a re-run, wipes the cache and drops every other -D, so the re-run would fail.
build_dep() { # <variant>
  local v="$1" flags; eval "flags=\$CFLAGS_$v"
  cmake -S deps/pcre2 -B "$B/$v/pcre2" -G Ninja \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DPCRE2_STATIC_PIC=ON -DPCRE2_SUPPORT_JIT=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SHOW_REPORT=OFF >"$B/$v-pcre2.log" 2>&1
  cmake --build "$B/$v/pcre2" -j"$MAYHEM_JOBS" >>"$B/$v-pcre2.log" 2>&1
  cmake -S deps/uriparser -B "$B/$v/uriparser" -G Ninja \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DURIPARSER_BUILD_TESTS=OFF -DURIPARSER_BUILD_TOOLS=OFF \
    -DURIPARSER_BUILD_DOCS=OFF -DURIPARSER_BUILD_WCHAR_T=OFF >"$B/$v-uriparser.log" 2>&1
  cmake --build "$B/$v/uriparser" -j"$MAYHEM_JOBS" >>"$B/$v-uriparser.log" 2>&1
}

# --- omnigres' own code ---
compile() { # <variant> <language: c|cxx> <source> [extra flags...]; object lands in $B/<variant>/<name>.o
  local v="$1" lang="$2" src="$3"; shift 3
  local flags; eval "flags=\$CFLAGS_$v"
  local out="$B/$v/$(basename "${src%.*}").o"
  if [ "$lang" = c ]; then
    "$CC" $flags $PG_INC "$@" -c "$src" -o "$out" || { : > "$FAILED"; return 1; }
  else
    "$CXX" -std=c++20 $flags $PG_INC "$@" -c "$src" -o "$out" || { : > "$FAILED"; return 1; }
  fi
}

build_objects() { # <variant>
  local v="$1" f
  mkdir -p "$B/$v"
  for f in $SQL_SRCS; do
    compile "$v" c "$f" -I$OMNI_SQL & wait_slot
  done
  compile "$v" c $OMNI_WEB/urlencode.c & wait_slot
  compile "$v" c $OMNI_WEB/omni_web.c -Ilibpgaug -Ideps/uriparser/include & wait_slot
  compile "$v" cxx $OMNI_WEB/urlpattern.cpp -I$ADA -I"$B/$v/pcre2" -I$OMNI_WEB & wait_slot
  compile "$v" cxx $ADA/ada.cpp -I$ADA -I"$B/$v/pcre2" & wait_slot
  compile "$v" cxx $ADA/pcre2.cpp -I$ADA -I"$B/$v/pcre2" & wait_slot
  compile "$v" c mayhem/pg_shim.c -Imayhem & wait_slot
  compile "$v" c mayhem/kat.c -I$OMNI_SQL -Imayhem & wait_slot
  for f in mayhem/fuzz_*.c; do
    compile "$v" c "$f" -I$OMNI_SQL -Imayhem & wait_slot
  done
  wait_all
}

# Failures are recorded in a marker file, not via `wait -n`'s status (which races with already-reaped jobs).
FAILED="$B/.failed"; rm -f "$FAILED"
wait_slot() { while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || true; done; }
wait_all() { wait || true; [ ! -e "$FAILED" ] || { echo "build.sh: a compile failed" >&2; exit 1; }; }

# dependencies first (they produce the pcre2.h that ada's sources include), then objects, per variant
{ build_dep san || : > "$FAILED"; } &
{ build_dep plain || : > "$FAILED"; } &
wait_all
build_objects san
build_objects plain

# --- 1) the fuzzers: each linked once against libFuzzer and once against the run-once standalone driver ---
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/san/standalone_main.o"
"$CXX" $SANITIZER_FLAGS -c mayhem/lsan_off.cc -o "$B/san/lsan_off.o"

S="$B/san"
SQL_OBJS="$S/deparse.o $S/deparse_13.o $S/deparse_14.o $S/deparse_15.o $S/deparse_16.o $S/deparse_17.o
          $S/deparse_18.o $S/deparse_19.o $S/lib.o"
URIPARSER="$S/uriparser/liburiparser.a"
PCRE2="$S/pcre2/libpcre2-8.a"

link_fuzzer() { # <target> <linker> <objects and libraries...>
  local t="$1" ld="$2"; shift 2
  "$ld" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$S/fuzz_$t.o" "$S/lsan_off.o" "$@" -o "/mayhem/fuzz_$t"
  "$ld" $SANITIZER_FLAGS $DEBUG_FLAGS "$B/san/standalone_main.o" "$S/fuzz_$t.o" "$S/lsan_off.o" "$@" -o "/mayhem/fuzz_$t-standalone"
}

link_fuzzer omni_sql_deparse "$CC" $SQL_OBJS "$S/pg_shim.o" $PG_LIBS
link_fuzzer omni_web_codec "$CC" "$S/urlencode.o" "$S/pg_shim.o" $PG_LIBS
link_fuzzer omni_web_query_string "$CC" "$S/omni_web.o" "$S/pg_shim.o" "$URIPARSER" $PG_LIBS
link_fuzzer omni_web_urlpattern "$CXX" "$S/urlpattern.o" "$S/ada.o" "$S/pcre2.o" "$PCRE2" "$S/pg_shim.o" $PG_LIBS

# --- 2) the known-answer probe, from the project's normal (unsanitized, uninstrumented) build; the
# PostgreSQL archive underneath it is the one sanitized artifact, so its runtime is linked in ---
P="$B/plain"
"$CXX" $PG_SAN $COVERAGE_FLAGS "$P/kat.o" $P/deparse.o $P/deparse_13.o $P/deparse_14.o $P/deparse_15.o \
  $P/deparse_16.o $P/deparse_17.o $P/deparse_18.o $P/deparse_19.o $P/lib.o "$P/urlencode.o" "$P/omni_web.o" \
  "$P/urlpattern.o" "$P/ada.o" "$P/pcre2.o" "$P/pg_shim.o" "$P/uriparser/liburiparser.a" "$P/pcre2/libpcre2-8.a" \
  $PG_LIBS -o /mayhem/mayhem-kat
