// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on

#include <mb/pg_wchar.h>
#include <miscadmin.h>
#include <tcop/tcopprot.h>
#include <utils/guc_hooks.h>
#include <utils/elog.h>

#include "pg_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Normally defined by the backend's main.c, which is left out so that the fuzzer supplies main(). */
const char *progname = "omnigres-fuzz";

/*
 * Keep stderr quiet, and surface what PostgreSQL reports (MEMORY_CONTEXT_CHECKING) as a mere WARNING when a palloc'd
 * chunk was written past its end (MEMORY_CONTEXT_CHECKING): ASan cannot see inside PostgreSQL's allocator.
 */
static void mayhem_emit_log(ErrorData *edata) {
  if (edata->elevel == WARNING && edata->message != NULL &&
      strstr(edata->message, "detected write past chunk end") != NULL) {
    fprintf(stderr, "mayhem: %s\n", edata->message);
    abort();
  }
  edata->output_to_server = false;
  edata->output_to_client = false;
}

void mayhem_pg_init(void) {
  static bool initialized = false;
  if (initialized) {
    return;
  }
  initialized = true;
  MyProcPid = getpid();
  MemoryContextInit();
  assign_max_stack_depth(2048, NULL); /* the server default, in kB */
  set_stack_base();
  SetDatabaseEncoding(PG_UTF8);
  emit_log_hook = mayhem_emit_log;
}

MemoryContext mayhem_pg_begin(MemoryContext *iteration) {
  *iteration = AllocSetContextCreate(TopMemoryContext, "mayhem iteration", ALLOCSET_DEFAULT_SIZES);
  return MemoryContextSwitchTo(*iteration);
}

void mayhem_pg_end(MemoryContext old, MemoryContext iteration, bool errored) {
  MemoryContextSwitchTo(old);
  if (errored) {
    FlushErrorState();
  }
  MemoryContextDelete(iteration);
}

text *mayhem_text(const uint8_t *data, size_t size) {
  text *t = (text *)malloc(VARHDRSZ + size);
  SET_VARSIZE(t, VARHDRSZ + size);
  memcpy(VARDATA(t), data, size);
  return t;
}

bool mayhem_valid_text(const uint8_t *data, size_t size) {
  return memchr(data, 0, size) == NULL && pg_verifymbstr((const char *)data, (int)size, true);
}
