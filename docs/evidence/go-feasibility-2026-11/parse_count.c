// Parses every path on stdin with tree-sitter-go and counts files whose tree
// contains an error or missing node.
#include <tree_sitter/api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const TSLanguage *tree_sitter_go(void);

int main(void) {
    TSParser *parser = ts_parser_new();
    if (!ts_parser_set_language(parser, tree_sitter_go())) {
        puts("ABI_REJECTED");
        return 2;
    }
    long files = 0, bad = 0, bytes = 0;
    char path[4096];
    while (fgets(path, sizeof path, stdin)) {
        path[strcspn(path, "\n")] = 0;
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *buf = malloc(n + 1);
        if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); continue; }
        fclose(f);
        TSTree *tree = ts_parser_parse_string(parser, NULL, buf, (uint32_t)n);
        files++;
        bytes += n;
        if (ts_node_has_error(ts_tree_root_node(tree))) {
            bad++;
            // First error or missing node in document order.
            TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
            unsigned row = 0;
            for (;;) {
                TSNode node = ts_tree_cursor_current_node(&cursor);
                if (ts_node_is_error(node) || ts_node_is_missing(node)) {
                    row = ts_node_start_point(node).row + 1;
                    break;
                }
                if (ts_node_has_error(node) && ts_tree_cursor_goto_first_child(&cursor)) continue;
                while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
                    if (!ts_tree_cursor_goto_parent(&cursor)) goto done;
                }
            }
        done:
            ts_tree_cursor_delete(&cursor);
            if (bad <= 12) printf("ERR %s:%u\n", path, row);
        }
        ts_tree_delete(tree);
        free(buf);
    }
    printf("files=%ld error_files=%ld bytes=%ld abi=%u\n", files, bad, bytes,
           ts_language_abi_version(tree_sitter_go()));
    return 0;
}
