// omni_web.match(): URLPattern matching (ada's URLPattern with the PCRE2 regex provider).
// Input is  pattern '\n' input [ '\n' baseURL ]  — a missing baseURL is the SQL NULL.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <stdbool.h>

#include "pg_shim.h"

bool matches(char *pattern_data, size_t pattern_size, char *input_data, size_t input_size,
             char *baseurl_data, size_t baseurl_size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // match() receives text from a server, so only valid UTF-8 without NULs reaches it
  if (size > 16384 || !(mayhem_pg_init(), mayhem_valid_text(data, size))) {
    return -1;
  }
  char *pattern = (char *)data;
  size_t pattern_size = size;
  char *input = (char *)data + size;
  size_t input_size = 0;
  char *base = NULL;
  size_t base_size = 0;

  char *nl = memchr(data, '\n', size);
  if (nl != NULL) {
    pattern_size = (size_t)(nl - pattern);
    input = nl + 1;
    input_size = size - pattern_size - 1;
    char *nl2 = memchr(input, '\n', input_size);
    if (nl2 != NULL) {
      base = nl2 + 1;
      base_size = input_size - (size_t)(nl2 - input) - 1;
      input_size = (size_t)(nl2 - input);
    }
  }

  (void)matches(pattern, pattern_size, input, input_size, base, base_size);
  return 0;
}
