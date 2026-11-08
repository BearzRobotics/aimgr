/* Smoke test of the experimental C interface: parse, render, free, errors. */
#include <stdio.h>
#include <string.h>
#include "md.h"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int contains(const uint8_t *s, size_t n, const char *needle) {
    size_t m = strlen(needle);
    for (size_t i = 0; i + m <= n; i++) if (memcmp(s + i, needle, m) == 0) return 1;
    return 0;
}

int main(void) {
    const char *src = "# Hi\n\nterm\n: def\n\n| a |\n| - |\n| 1 |\n";
    md_document *doc = NULL;
    CHECK(md_parse((const uint8_t *)src, strlen(src), MD_EXT_ALL, &doc) == MD_OK);
    CHECK(doc != NULL);

    uint8_t *html = NULL; size_t html_len = 0;
    CHECK(md_to_html(doc, &html, &html_len) == MD_OK);
    CHECK(contains(html, html_len, "<h1>Hi</h1>"));
    CHECK(contains(html, html_len, "<dl>"));
    CHECK(contains(html, html_len, "<table>"));
    md_free_string(html, html_len);

    uint8_t *text = NULL; size_t text_len = 0;
    CHECK(md_to_text(doc, 40, 0, &text, &text_len) == MD_OK);
    CHECK(contains(text, text_len, "Hi"));
    md_free_string(text, text_len);

    /* Without extensions the table is plain text. */
    md_document *plain = NULL;
    CHECK(md_parse((const uint8_t *)src, strlen(src), 0, &plain) == MD_OK);
    CHECK(md_to_html(plain, &html, &html_len) == MD_OK);
    CHECK(!contains(html, html_len, "<table>"));
    md_free_string(html, html_len);
    md_free(plain);

    /* Empty input and error paths. */
    md_document *empty = NULL;
    CHECK(md_parse(NULL, 0, 0, &empty) == MD_OK);
    md_free(empty);
    CHECK(md_parse(NULL, 5, 0, &empty) == MD_ERR_INVALID_ARGUMENT);
    CHECK(empty == NULL);
    CHECK(md_parse((const uint8_t *)"x", 1, 0, NULL) == MD_ERR_INVALID_ARGUMENT);
    CHECK(md_to_html(NULL, &html, &html_len) == MD_ERR_INVALID_ARGUMENT);
    md_free(NULL);
    md_free_string(NULL, 0);

    md_free(doc);
    CHECK(strcmp(md_version(), "0.3.0") == 0);
    if (fails == 0) printf("c api ok\n");
    return fails ? 1 : 0;
}
