CC = gcc
CFLAGS = -Wall -Wextra -g
TARGETS = no_memory_sim memory_sim

all: $(TARGETS)

memory_sim: memory_sim.o

memory_sim.o: memory_sim.c heap.h mmu.h

no_memory_sim: no_memory_sim.o

no_memory_sim.o: no_memory_sim.c heap.h mmu.h

.PHONY: clean
clean:
	rm -f *.o a.out core no_memory_sim memory_sim
