// Known-answer probe for mayhem/test.sh: runs omnigres' own functions on argv and prints the result, so the
// test can compare exact values (taken from extensions/*/tests/*.yml) from a dynamically linked binary.
//   mayhem-kat url_encode|url_decode|uri_encode|uri_decode <text>
//   mayhem-kat deparse <sql>          (statements re-rendered by omni_sql's deparser)
//   mayhem-kat returning|replace|parameterized <sql>
//   mayhem-kat query <query string>   ({k,v,...}, NULL for a missing key/value)
//   mayhem-kat match <pattern> <input> [<baseURL>]
// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <catalog/pg_type.h>
#include <utils/array.h>

#include <varatt.h>

#include <stdio.h>
#include <string.h>

#include "omni_sql.h"
#include "pg_shim.h"

Datum url_encode(PG_FUNCTION_ARGS);
Datum url_decode(PG_FUNCTION_ARGS);
Datum uri_encode(PG_FUNCTION_ARGS);
Datum uri_decode(PG_FUNCTION_ARGS);
Datum parse_query_string(PG_FUNCTION_ARGS);
bool matches(char *pattern_data, size_t pattern_size, char *input_data, size_t input_size,
             char *baseurl_data, size_t baseurl_size);

static int usage(void) {
  fprintf(stderr, "usage: mayhem-kat <op> <arg> [<arg>]\n");
  return 2;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    return usage();
  }
  const char *op = argv[1];
  char *arg = argv[2];

  if (strcmp(op, "match") == 0) {
    if (argc < 4) {
      return usage();
    }
    char *base = argc > 4 ? argv[4] : NULL;
    bool ok = matches(arg, strlen(arg), argv[3], strlen(argv[3]), base, base ? strlen(base) : 0);
    puts(ok ? "true" : "false");
    return 0;
  }

  mayhem_pg_init();
  MemoryContext iteration;
  mayhem_pg_begin(&iteration);
  int rc = 0;

  PG_TRY();
  {
    PGFunction codec = strcmp(op, "url_encode") == 0   ? url_encode
                       : strcmp(op, "url_decode") == 0 ? url_decode
                       : strcmp(op, "uri_encode") == 0 ? uri_encode
                       : strcmp(op, "uri_decode") == 0 ? uri_decode
                                                       : NULL;
    if (codec != NULL) {
      text *result = DatumGetTextPP(DirectFunctionCall1(codec, CStringGetTextDatum(arg)));
      printf("%.*s\n", (int)VARSIZE_ANY_EXHDR(result), VARDATA_ANY(result));
    } else if (strcmp(op, "deparse") == 0) {
      puts(omni_sql_deparse_statement(omni_sql_parse_statement(arg)));
    } else if (strcmp(op, "returning") == 0) {
      puts(omni_sql_is_returning_statement(omni_sql_parse_statement(arg)) ? "true" : "false");
    } else if (strcmp(op, "replace") == 0) {
      puts(omni_sql_is_replace_statement(omni_sql_parse_statement(arg)) ? "true" : "false");
    } else if (strcmp(op, "parameterized") == 0) {
      puts(omni_sql_is_parameterized(omni_sql_parse_statement(arg)) ? "true" : "false");
    } else if (strcmp(op, "query") == 0) {
      ArrayType *result =
          DatumGetArrayTypeP(DirectFunctionCall1(parse_query_string, CStringGetTextDatum(arg)));
      Datum *elems;
      bool *nulls;
      int n;
      deconstruct_array(result, TEXTOID, -1, false, TYPALIGN_INT, &elems, &nulls, &n);
      putchar('{');
      for (int i = 0; i < n; i++) {
        if (i > 0) {
          putchar(',');
        }
        if (nulls[i]) {
          fputs("NULL", stdout);
        } else {
          fputs(TextDatumGetCString(elems[i]), stdout);
        }
      }
      puts("}");
    } else {
      rc = usage();
    }
  }
  PG_CATCH();
  {
    MemoryContextSwitchTo(iteration);
    ErrorData *err = CopyErrorData();
    printf("ERROR: %s\n", err->message);
    rc = 1;
  }
  PG_END_TRY();
  return rc;
}
