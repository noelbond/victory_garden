#include <stdio.h>
#include "pico/stdlib.h"

int main(void) {
    stdio_init_all();
    sleep_ms(2000);
    int i = 0;
    while (true) {
        printf("alive tick=%d\n", i++);
        stdio_flush();
        sleep_ms(500);
    }
}
