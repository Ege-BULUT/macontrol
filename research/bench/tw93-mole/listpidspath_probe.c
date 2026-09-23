#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  for (int a = 1; a < argc; a++) {
    int n = proc_listpidspath(PROC_ALL_PIDS, 0, argv[a], PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, NULL, 0);
    int *buf = malloc(n > 0 ? n : 4);
    n = proc_listpidspath(PROC_ALL_PIDS, 0, argv[a], PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, buf, n);
    printf("%s -> %d pid(s):", argv[a], n > 0 ? n / (int)sizeof(int) : n);
    for (int i = 0; n > 0 && i < n / (int)sizeof(int); i++) printf(" %d", buf[i]);
    printf("\n");
  }
  return 0;
}
