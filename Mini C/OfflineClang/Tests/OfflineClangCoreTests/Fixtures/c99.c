#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
struct Pair { int x, y; };
int main(void) {
    struct Pair p = {.y = 7, .x = 3};
    int n = 4, a[n];
    for (int i = 0; i < n; ++i) a[i] = i * i;
    uint32_t u = UINT32_MAX;
    bool ok = (u + 1u == 0);
    printf("%d %d %d %zu %d\n", p.x, p.y, a[3], sizeof(char), ok);
    return 0;
}