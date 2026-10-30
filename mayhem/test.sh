#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer checks of omnigres' own functions (the binary is built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# omnigres' real suite (pg_yregress over a running PostgreSQL with the extensions installed) needs a full
# server build, so this drives the same functions in-process through mayhem/kat.c (`mayhem-kat`), a normally
# built, dynamically linked binary, and compares exact results taken from extensions/*/tests/*.yml.
# A patch that makes the code exit(0) or print nothing fails every one of these comparisons.
KAT=/mayhem/mayhem-kat
if [ ! -x "$KAT" ]; then
  echo "test.sh: $KAT is missing — mayhem/build.sh should have built it" >&2
  emit_ctrf "mayhem-kat" 0 1 0
  exit 1
fi

passed=0; failed=0
# check <expected stdout> <op> <args...>
check() {
  local want="$1"; shift
  local got
  got="$("$KAT" "$@" 2>&1)"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: mayhem-kat %s\n  want: %s\n  got:  %s\n' "$*" "$want" "$got" >&2
  fi
}

# omni_web: extensions/omni_web/tests/urlencode.yml, query_string.yml
check 'Hello%20World'                                    url_encode 'Hello World'
check 'Hello World'                                      url_decode 'Hello%20World'
check 'a%2Fb%3Fc%3Dd%26%C3%A9'                           url_encode 'a/b?c=d&é'
check 'a/b?c=d&é'                                        url_decode 'a%2Fb%3Fc%3Dd%26%C3%A9'
check 'http://hu.wikipedia.org/wiki/S%C3%A3o_Paulo'      uri_encode 'http://hu.wikipedia.org/wiki/São_Paulo'
check 'http://hu.wikipedia.org/wiki/São_Paulo'           uri_decode 'http://hu.wikipedia.org/wiki/S%C3%A3o_Paulo'
check '{a,x,b,1}'                                        query 'a=x&b=1'
check '{a,NULL}'                                         query 'a'
check '{a, ,b,1 3}'                                      query 'a=%20&b=1+3'
check '{k,v&w,k2,NULL}'                                  query 'k=v%26w&k2'
check 'ERROR: unaccepted chars in url code'              url_decode 'Hello%20World+x'

# omni_web: extensions/omni_web/tests/urlpattern.yml (pattern, input[, baseURL])
check 'true'                                             match '/:resource/:action' '/product/edit'
check 'false'                                            match '/:resource/:action' 'https://example.com/product/edit' 'https://foo.bar'
check 'false'                                            match '/foo' '/bar'

# omni_sql: statements re-rendered by the deparser, and its predicates
check 'SELECT 1 + 1 AS x FROM t WHERE a = $1'            deparse 'select 1+1 as x from t where a=$1'
check 'INSERT INTO t VALUES (1) RETURNING *'             deparse 'insert into t values (1) returning *'
check 'WITH x AS (SELECT 1) SELECT * FROM x ORDER BY 1 LIMIT 2' \
                                                         deparse 'with x as (select 1) select * from x order by 1 limit 2'
check 'ERROR: syntax error at or near "selec"'          deparse 'selec 1'
check 'true'                                             returning 'insert into t values (1) returning *'
check 'false'                                            returning 'insert into t values (1)'
check 'true'                                             replace 'create or replace function f() returns int as $$ select 1 $$ language sql'
check 'false'                                            replace 'create table t()'
check 'true'                                             parameterized 'select $1'
check 'false'                                            parameterized 'select 1'

emit_ctrf "mayhem-kat" "$passed" "$failed" 0
