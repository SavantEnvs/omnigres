#ifndef MAYHEM_PG_SHIM_H
#define MAYHEM_PG_SHIM_H

// clang-format off
#include <postgres.h>
#include <fmgr.h>
// clang-format on
#include <utils/memutils.h>

/* Bring the linked-in PostgreSQL backend up far enough to run parser/palloc/ereport code. Idempotent. */
void mayhem_pg_init(void);

/* Run each iteration in a throw-away memory context; mayhem_pg_end() discards it (and a pending ERROR). */
MemoryContext mayhem_pg_begin(MemoryContext *iteration);
void mayhem_pg_end(MemoryContext old, MemoryContext iteration, bool errored);

/* A text datum over an exact-size malloc() block, so ASan sees any read past the end of the input. */
text *mayhem_text(const uint8_t *data, size_t size);

/* Input must be what a PostgreSQL server would have accepted: no NULs, valid in the database encoding. */
bool mayhem_valid_text(const uint8_t *data, size_t size);

#endif
