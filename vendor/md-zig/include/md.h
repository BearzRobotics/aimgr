/*
 * md-zig C interface.
 *
 * EXPERIMENTAL AND UNSTABLE: names, signatures and behaviour may change between
 * releases; there is no source or binary compatibility guarantee. The native Zig
 * module is the primary interface (see README.md).
 *
 * Ownership: md_parse returns a document that the caller releases with md_free.
 * Strings returned by md_to_html and md_to_text are NOT NUL terminated; use the
 * returned length and release them with md_free_string(ptr, len). No function
 * keeps a pointer to caller memory after it returns. A document must not be
 * used from two threads at once; distinct documents are independent.
 */
#ifndef MD_ZIG_H
#define MD_ZIG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct md_document md_document;

/* Status codes. */
#define MD_OK 0
#define MD_ERR_INVALID_ARGUMENT 1
#define MD_ERR_OUT_OF_MEMORY 2
#define MD_ERR_INPUT_TOO_LARGE 3
#define MD_ERR_LINE_TOO_LONG 4
#define MD_ERR_READ_FAILED 5

/* Extension flags for md_parse (combine with |). 0 is plain CommonMark. */
#define MD_EXT_TABLES (1u << 0)
#define MD_EXT_STRIKETHROUGH (1u << 1)
#define MD_EXT_TASK_LISTS (1u << 2)
#define MD_EXT_AUTOLINKS (1u << 3)
#define MD_EXT_TAGFILTER (1u << 4)
#define MD_EXT_FOOTNOTES (1u << 5)
#define MD_EXT_FRONT_MATTER (1u << 6)
#define MD_EXT_DEFINITION_LISTS (1u << 7)
#define MD_EXT_GFM (MD_EXT_TABLES | MD_EXT_STRIKETHROUGH | MD_EXT_TASK_LISTS | MD_EXT_AUTOLINKS | MD_EXT_TAGFILTER)
#define MD_EXT_ALL (MD_EXT_GFM | MD_EXT_FOOTNOTES | MD_EXT_FRONT_MATTER | MD_EXT_DEFINITION_LISTS)

/* Library version, a static NUL terminated string. */
const char *md_version(void);

/* Parses `len` bytes at `src` (src may be NULL only when len is 0). On MD_OK,
 * *out is a new document. On error *out is set to NULL. */
int md_parse(const uint8_t *src, size_t len, uint32_t extensions, md_document **out);

/* Releases a document. NULL is allowed. */
void md_free(md_document *doc);

/* HTML for the document. */
int md_to_html(const md_document *doc, uint8_t **out, size_t *out_len);

/* Text for a terminal. width 0 means do not wrap; color nonzero adds ANSI styles. */
int md_to_text(const md_document *doc, size_t width, int color, uint8_t **out, size_t *out_len);

/* Releases a string returned by md_to_html or md_to_text. NULL is allowed. */
void md_free_string(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
