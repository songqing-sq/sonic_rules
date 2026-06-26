/* Smoke link test for @popt_src//:popt — confirms libpopt.a links cleanly
 * (no undefined symbols) and that the most-used entry points behave. */
#include <popt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    int argc = 0;
    const char **argv = NULL;
    int rc = poptParseArgvString("a b c", &argc, &argv);
    if (rc != 0 || argc != 3 || !argv) {
        fprintf(stderr, "poptParseArgvString failed: rc=%d argc=%d\n", rc, argc);
        return 1;
    }
    if (strcmp(argv[0], "a") || strcmp(argv[1], "b") || strcmp(argv[2], "c")) {
        fprintf(stderr, "argv mismatch: %s|%s|%s\n", argv[0], argv[1], argv[2]);
        free(argv);
        return 1;
    }
    free(argv);
    return 0;
}
