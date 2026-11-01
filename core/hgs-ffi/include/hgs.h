#ifndef HGS_H
#define HGS_H
#ifdef __cplusplus
extern "C" {
#endif
/* All inputs must be valid NUL-terminated UTF-8 allocations; handles must remain
 * live. Serialize calls for each engine. Returned owned strings use hgs_string_free.
 * Max input bytes: document 8388608, command 262144, query 65536; name 200 Unicode
 * scalar values (at most 800 UTF-8 bytes). Oversize inputs fail before parsing. */
typedef struct HgsEngine HgsEngine;
const char *hgs_version(void); /* Static; do not free. */
HgsEngine *hgs_engine_new(const char *name_utf8); /* NULL name = default; NULL result = failure. */
HgsEngine *hgs_engine_open(const char *project_json, char **error_out);
void hgs_engine_free(HgsEngine *engine); /* NULL-safe; free once. */
char *hgs_engine_command(HgsEngine *engine, const char *command_json);
char *hgs_engine_query(HgsEngine *engine, const char *query_json);
void hgs_string_free(char *s); /* NULL-safe; free once. */
#ifdef __cplusplus
}
#endif
#endif
