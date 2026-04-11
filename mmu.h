#ifndef _MMU_H_
#define _MMU_H_

#include "heap.h"
#define PAGE_SIZE 16
#define MAX_PAGES 64
#define MAX_PAGES_PER_SYMBOL 8
#define OVERFLOW_PAGE_SIZE 16
#define TLB_HIT_CYCLES 1
#define TLB_MISS_CYCLES 3
#define OVERFLOW_PENALTY_CYCLES 2

typedef struct {
	int frame_index;
	int owner_symbol;
	int node_count;
} PhysicalFrame;

typedef struct {
	int virtual_page;
	int physical_frame;
} TLBEntry;

typedef struct {
	int data[OVERFLOW_PAGE_SIZE];
	int cnt;
} OverflowPage;

typedef struct {
	PhysicalFrame frames[MAX_PAGES];
	uint64_t free_bitmap; //change type to best represent max number of pages
	TLBEntry tlb[16]; //change number for size of tlb
	int tlb_size;
	int tlb_misses;
	int tlb_hits;
	int hard_rejects;
	OverflowPage overflow;
} MemoryManager;

typedef struct {
	int virtual_pages[MAX_PAGES_PER_SYMBOL];
	int page_count;
	int nodes_in_curr_page;
} SymbolMemory;

typedef struct {
	char symbol[8];
	Heap *asks;
	Heap *bids;
	int trades;
	SymbolMemory mem;
	int trade_in_progress;
	int insert_pending;
} OrderBook;

typedef struct {
	OrderBook **books;
	int cnt;
	int cap;
} Exchange;

typedef struct {
	int total_trades;
	int total_reads;
	int total_writes;
	int tlb_misses;
	int tlb_hits;
	int overflow_accesses;
	int hard_rejects;
	int hazards;
	long long total_cycles;
} SimStats;

MemoryManager *create_memory_manager(void) {
	MemoryManager *mm = malloc(sizeof(MemoryManager));

	for (int i = 0; i < MAX_PAGES; i++) {
		mm->frames[i].frame_index = i;
		mm->frames[i].owner_symbol = -1;
		mm->frames[i].node_count = 0;
	}

	mm->free_bitmap = (MAX_PAGES == 64) ? ~0ULL : (1ULL << MAX_PAGES) - 1;
	mm->tlb_size = 0;
	mm->tlb_hits = 0;
	mm->tlb_misses = 0;
	mm->hard_rejects = 0;
	mm->overflow.cnt = 0;

	return mm;
}

int translate(MemoryManager *mm, int symbol_id, int virtual_page) {
	for (int i = 0; i < mm->tlb_size; i++) {
		if (mm->tlb[i].virtual_page == virtual_page) {
			int frame = mm->tlb[i].physical_frame;
			if(mm->frames[frame].owner_symbol == symbol_id) {
				mm->tlb_hits++;
				return frame;
			}
			mm->tlb[i].virtual_page = -1;
			mm->tlb_misses++;
			return -1;
		}
	}

	mm->tlb_misses++;
	return -1;
}

void tlb_insert(MemoryManager *mm, int virtual_page, int physical_frame) {
	if (mm->tlb_size < 16) {
		mm->tlb[mm->tlb_size].virtual_page = virtual_page;
		mm->tlb[mm->tlb_size].physical_frame = physical_frame;
		mm->tlb_size++;
	} else {
		for (int i = 0; i < 15; i++) {
			mm->tlb[i] = mm->tlb[i + 1];
			mm->tlb[15].virtual_page = virtual_page;
			mm->tlb[15].physical_frame = physical_frame;
		}
	}
}

int allocate_frame(MemoryManager *mm, int symbol_id) {
	for (int i = 0; i < MAX_PAGES; i++) {
		if (mm->free_bitmap & (1ULL << i)) {
			mm->free_bitmap &= ~(1ULL << i);
			mm->frames[i].owner_symbol = symbol_id;
			mm->frames[i].node_count = 0;
			return i;
		}		
	}
	return -1;
}

void free_frame(MemoryManager *mm, int frame_index) {
	mm->free_bitmap |= (1ULL << frame_index);
	mm->frames[frame_index].owner_symbol = -1;
	mm->frames[frame_index].node_count = 0;
	for (int i = 0; i < mm->tlb_size; i++) {
		if (mm->tlb[i].physical_frame == frame_index) {
			mm->tlb[i].virtual_page = -1;
			mm->tlb[i].physical_frame = -1;
		}
	}
}

Exchange *create_exchange(int cap) {
	Exchange *ex = malloc(sizeof(Exchange));
	ex->books = malloc(sizeof(OrderBook *) * cap);
	ex->cnt = 0;
	ex->cap = cap;
	return ex;
}

OrderBook *create_order_book(const char *symbol) {
	OrderBook *ob = malloc(sizeof(OrderBook));
	strncpy(ob->symbol, symbol, 3);
	ob->symbol[3] = '\0';
	ob->asks = create_heap(10, min_cmp);
	ob->bids = create_heap(10, max_cmp);
	ob->trades = 0;
	ob->trade_in_progress = 0;
	ob->insert_pending = 0;
	ob->mem.page_count = 0;
	ob->mem.nodes_in_curr_page = 0;
	return ob;
}

OrderBook *find_or_create_book(Exchange *ex, const char *symbol) {
	for (int i = 0; i < ex->cnt; i++) {
		if (strcmp(ex->books[i]->symbol, symbol) == 0) {
			return ex->books[i];
		}
	}

	if (ex->cnt >= ex->cap) {
		ex->cap *= 2;
		ex->books = realloc(ex->books, sizeof(OrderBook *) * ex->cap);
	}

	OrderBook *ob = create_order_book(symbol);
	ex->books[ex->cnt++] = ob;
	return ob;
}

void free_exchange(Exchange *ex) {
	for (int i = 0; i < ex->cnt; i++) {
		free_heap(ex->books[i]->asks);
		free_heap(ex->books[i]->bids);
		free(ex->books[i]);
	}
	free(ex->books);
	free(ex);
}

int mem_aware_insert(OrderBook *ob, MemoryManager *mm, Order *o, int sym_id, SimStats *stats) {
	if (ob->mem.page_count > 0 && ob->mem.nodes_in_curr_page < PAGE_SIZE) { //room in curr page
		int frame = ob->mem.virtual_pages[ob->mem.page_count - 1];
		int vpage = sym_id * MAX_PAGES_PER_SYMBOL + ob->mem.page_count - 1;

		if (translate(mm, sym_id, vpage) >= 0) {
			stats->total_cycles += TLB_HIT_CYCLES;
		} else {
			stats->total_cycles += TLB_MISS_CYCLES;
			tlb_insert(mm, vpage, frame);
		}

		ob->mem.nodes_in_curr_page++;
		mm->frames[frame].node_count++;
		stats->total_writes++;

		if (o->type) {
			push(ob->asks, o);
		} else {
			push(ob->bids, o);
		}

		return 1;
	}

	
	if (ob->mem.page_count < MAX_PAGES_PER_SYMBOL) { //new page
		int frame = allocate_frame(mm, sym_id);

		if (frame >= 0) {
			ob->mem.virtual_pages[ob->mem.page_count++] = frame;
			ob->mem.nodes_in_curr_page = 1;
			mm->frames[frame].node_count = 1;
			stats->total_cycles += TLB_MISS_CYCLES;
			tlb_insert(mm, sym_id * MAX_PAGES_PER_SYMBOL + ob->mem.page_count - 1, frame);
			stats->total_writes++;

			if (o->type) {
				push(ob->asks, o);
			} else {
				push(ob->bids, o);
				return 1;
			}
		}
	}

	if (mm->overflow.cnt < OVERFLOW_PAGE_SIZE) { //use overflow page
		mm->overflow.cnt++;
		stats->total_cycles += TLB_MISS_CYCLES + OVERFLOW_PENALTY_CYCLES;
		stats->overflow_accesses++;
		stats->total_writes++;

		printf("[OVERFLOW] %s using shared overflow (%d/%d) +%d cycles\n",
				ob->symbol,
			       	mm->overflow.cnt,
			       	OVERFLOW_PAGE_SIZE,
				TLB_MISS_CYCLES + OVERFLOW_PENALTY_CYCLES);

		if (o->type) {
			push(ob->asks, o);
		} else {
			push(ob->bids, o);
		}

		return 1;
	}

	//hard reject
	mm->hard_rejects++;
	stats->total_cycles += 1;

	printf("[HARD REJECT] %s order rejected: price=%d amount=%d\n",
			ob->symbol, o->price, o->amount);
	return 0;
}

int check_for_trade_multi(OrderBook *ob, SimStats *stats) {
	if (ob->asks->size == 0 || ob->bids->size == 0) {
		return 0;
	}

	Order *bid = (Order *) peek(ob->bids);
	Order *ask = (Order *) peek(ob->asks);

	stats->total_reads += 2;
	stats->total_cycles += TLB_HIT_CYCLES;

	if (bid->price >= ask->price) {
		if (bid->amount == ask->amount) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			printf("A trade has been executed at %d! Sold %d shares of %s at $%d.\n",
				(uint32_t) ts.tv_nsec,
				bid->amount,
			       	ob->symbol,
			       	bid->price);

			pop(ob->bids);
			pop(ob->asks);
			stats->total_trades++;

			return 1;
		} else if (bid->amount > ask->amount) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			printf("A partial fill has been executed at %d! Sold %d shares of %s at $%d. A bid for %d shares remains.\n",
					(uint32_t) ts.tv_nsec,
					ask->amount,
				       	ob->symbol,
				       	bid->price,
					bid->amount - ask->amount);

			update(ob->bids, bid->amount - ask->amount);
			pop(ob->asks);
			stats->total_trades++;
			stats->total_writes++;

			return 1;
		} else {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			printf("A partial fill has been executed at %d! Sold %d shares of %s at $%d. A ask of %d shares remains.\n",
				(uint32_t) ts.tv_nsec,
				bid->amount,
			       	ob->symbol,
			       	bid->price,
				ask->amount - bid->amount);

			update(ob->asks, ask->amount - bid->amount);
			pop(ob->bids);
			stats->total_trades++;
			stats->total_writes++;

			return 1;
		}
	} else {
		return 0;
	}
}

void post_trade_cleanup(MemoryManager *mm, OrderBook *ob) {
	if (mm->overflow.cnt > 0) {
		mm->overflow.cnt--;
	}

	if (ob->mem.nodes_in_curr_page > 0) {
		ob->mem.nodes_in_curr_page--;
		if (ob->mem.page_count > 0) {
			int frame = ob->mem.virtual_pages[ob->mem.page_count - 1];
			mm->frames[frame].node_count--;

			if (mm->frames[frame].node_count == 0) {
				free_frame(mm, frame);
				ob->mem.page_count--;

				if (ob->mem.page_count > 0) {
					ob->mem.nodes_in_curr_page = PAGE_SIZE;
				} else {
					ob->mem.nodes_in_curr_page = 0;
				}
																																}
																	}
	}
}

void print_sim_stats(Exchange *ex, MemoryManager *mm, SimStats *stats) {
	printf("Per-Symbol Breakdown:\n");
	for (int i = 0; i < ex->cnt; i++) {
		OrderBook *ob = ex->books[i];
		printf("%s: %d trades, %d open asks, %d open bids, %d pages used\n",
				ob->symbol,
			       	ob->trades,
			       	ob->asks->size,
			       	ob->bids->size,
				ob->mem.page_count);
	}

	printf("Memory:\n");
	printf("TLB hits:    %d\n", mm->tlb_hits);
	printf("TLB misses:  %d\n", mm->tlb_misses);
	printf("TLB hit rate: %.1f%%\n",
			(mm->tlb_hits + mm->tlb_misses) > 0 ? 100.0 * mm->tlb_hits / (mm->tlb_hits + mm->tlb_misses) : 0.0);

	printf("Overflow:\n");
	printf("Accesses:       %d\n", stats->overflow_accesses);
	printf("Current usage:  %d/%d\n", mm->overflow.cnt, OVERFLOW_PAGE_SIZE);
	printf("Penalty cycles: %d\n", stats->overflow_accesses * (TLB_MISS_CYCLES + OVERFLOW_PENALTY_CYCLES));

	printf("\nTotals:\n");
	printf("Hard rejects: %d\n", mm->hard_rejects);
	printf("Trades:       %d\n", stats->total_trades);
	printf("Reads:        %d\n", stats->total_reads);
	printf("Writes:       %d\n", stats->total_writes);
	printf("Cycles:       %lld\n", stats->total_cycles);
}

#endif
