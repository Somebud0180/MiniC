#include <stdio.h>
#include <string.h>
int main(void) { char b[4096]; memset(b, 'x', sizeof b); for (;;) fwrite(b, 1, sizeof b, stdout); }