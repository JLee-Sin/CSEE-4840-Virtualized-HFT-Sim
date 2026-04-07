CC = gcc
CFLAGS = -Wall -Wextra -g
LDFLAGS = 

no_memory_sim: no_memory_sim.o

no_memory_sim.o: no_memory_sim.c heap.h

.PHONY: clean
clean:
	rm -f *.o a.out core no_memory_sim

.PHONY: all
all: clean no_memory_sim
