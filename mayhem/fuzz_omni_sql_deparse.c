// Parses SQL text with the PostgreSQL grammar and runs omni_sql's statement deparser and classifiers
// (omni_sql.statement_* / is_returning_statement / is_replace_statement / is_parameterized) over the tree.
// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <stdlib.h>
#include <string.h>

#include "omni_sql.h"
#include "pg_shim.h"

/* Statements reach omni_sql as short text; keep the deparser's recursion within what a server would take. */
#define MAX_SQL_SIZE 16384

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0 || size > MAX_SQL_SIZE || !(mayhem_pg_init(), mayhem_valid_text(data, size))) {
    return -1;
  }

  char *sql = malloc(size + 1);
  memcpy(sql, data, size);
  sql[size] = '\0';

  MemoryContext iteration;
  MemoryContext old = mayhem_pg_begin(&iteration);
  volatile bool errored = false;
  volatile int rc = 0;

  PG_TRY();
  {
    List *stmts = omni_sql_parse_statement(sql);
    char *deparsed = omni_sql_deparse_statement(stmts);
    (void)omni_sql_is_parameterized(stmts);
    (void)omni_sql_is_returning_statement(stmts);
    (void)omni_sql_is_replace_statement(stmts);
    if (list_length(stmts) == 0) {
      rc = -1;
    }
    /* The deparsed form is meant to be SQL again: take it through the same path a second time. */
    List *again = omni_sql_parse_statement(deparsed);
    (void)omni_sql_deparse_statement(again);
  }
  PG_CATCH();
  {
    errored = true;
    rc = -1;
  }
  PG_END_TRY();

  mayhem_pg_end(old, iteration, errored);
  free(sql);
  return rc;
}
