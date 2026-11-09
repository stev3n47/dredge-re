#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void probe_init(void) {
    const char *h = getenv("HOME");
    char p[2048];
    snprintf(p, sizeof p, "%s/Documents/ipauto_probe.txt", h ? h : ".");
    FILE *f = fopen(p, "w");
    if (f) {
        fputs("ipauto probe dylib loaded and constructor ran\n", f);
        fclose(f);
    }
}
