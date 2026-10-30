// omni_web.parse_query_string(text) -> text[] (key, value, key, value, ...), over uriparser's query dissector.
// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <catalog/pg_type.h>
#include <utils/array.h>

#include <varatt.h>

#include <stdlib.h>
#include <string.h>

#include "pg_shim.h"

Datum parse_query_string(PG_FUNCTION_ARGS);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size > 65536 || !(mayhem_pg_init(), mayhem_valid_text(data, size))) {
    return -1;
  }

  text *input = mayhem_text(data, size);

  MemoryContext iteration;
  MemoryContext old = mayhem_pg_begin(&iteration);
  volatile bool errored = false;
  volatile int rc = 0;

  PG_TRY();
  {
    ArrayType *result =
        DatumGetArrayTypeP(DirectFunctionCall1(parse_query_string, PointerGetDatum(input)));
    Datum *elems;
    bool *nulls;
    int n;
    deconstruct_array(result, TEXTOID, -1, false, TYPALIGN_INT, &elems, &nulls, &n);
    if (n % 2 != 0) {
      abort();
    }
    for (int i = 0; i < n; i++) {
      if (!nulls[i]) {
        (void)VARSIZE_ANY_EXHDR(DatumGetTextPP(elems[i]));
      }
    }
  }
  PG_CATCH();
  {
    errored = true;
    rc = -1;
  }
  PG_END_TRY();

  mayhem_pg_end(old, iteration, errored);
  free(input);
  return rc;
}
