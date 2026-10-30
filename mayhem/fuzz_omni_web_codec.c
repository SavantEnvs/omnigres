// omni_web.url_encode / url_decode / uri_encode / uri_decode, called through their fmgr entry points.
// First byte picks the function; the encoders are also checked to round-trip through their decoders.
// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <varatt.h>

#include <stdlib.h>
#include <string.h>

#include "pg_shim.h"

Datum url_encode(PG_FUNCTION_ARGS);
Datum url_decode(PG_FUNCTION_ARGS);
Datum uri_encode(PG_FUNCTION_ARGS);
Datum uri_decode(PG_FUNCTION_ARGS);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1 || size > 65536) {
    return -1;
  }
  mayhem_pg_init();
  const uint8_t op = data[0] & 3;
  data++;
  size--;
  if (!mayhem_valid_text(data, size)) {
    return -1;
  }

  text *input = mayhem_text(data, size);

  MemoryContext iteration;
  MemoryContext old = mayhem_pg_begin(&iteration);
  volatile bool errored = false;
  volatile int rc = 0;

  PG_TRY();
  {
    switch (op) {
    case 0:
    case 1: {
      PGFunction encode = op == 0 ? url_encode : uri_encode;
      PGFunction decode = op == 0 ? url_decode : uri_decode;
      text *encoded = DatumGetTextPP(DirectFunctionCall1(encode, PointerGetDatum(input)));
      text *decoded = DatumGetTextPP(DirectFunctionCall1(decode, PointerGetDatum(encoded)));
      if (VARSIZE_ANY_EXHDR(decoded) != size || memcmp(VARDATA_ANY(decoded), data, size) != 0) {
        fprintf(stderr, "mayhem: %s round trip changed the input\n", op == 0 ? "url" : "uri");
        abort();
      }
      break;
    }
    case 2:
      (void)DirectFunctionCall1(url_decode, PointerGetDatum(input));
      break;
    case 3:
      (void)DirectFunctionCall1(uri_decode, PointerGetDatum(input));
      break;
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
