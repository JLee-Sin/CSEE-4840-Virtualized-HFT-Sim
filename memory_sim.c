#include <stdio.h>
#include <time.h>
#include <string.h>
#include "mmu.h"

static void automatic_execution(int orders) {
	//TODO
}

static void manual_execution() {
	//TODO
}

int main(int argc, char *argv[]) {
	int mode = DEFAULT_MODE;
        int orders = DEFAULT_ORDERS;

	for(int i = 1; i < argc; i++) {
		if(strcmp(argv[i], "--mode") == 0) {
			mode = atoi(argv[++i]);
		} else if(strcmp(argv[i], "--orders") == 0) {
			orders = atoi(argv[++i]);
		}
	}

	if(mode != 1 && mode != 0) {
		printf("Usage: mode must be either 1 (automatic) or 0 (manual) \n");
		return 1;
	}

	if(orders < 2) {
		printf("Usage: At least 2 orders must be submitted \n");
		return 1;
	}

	if(mode) {
		automatic_execution(orders);
	} else {
		manual_execution();
	}

	return 0;
}
