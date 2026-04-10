#ifndef _MMU_H_
#define _MMU_H_

#include "heap.h"
#define PAGE_SIZE 16
#define MAX_PAGES 64
#define MAX_PAGES_PER_SYMBOL 8
#define OVERFLOW_PAGE_SIZE 16

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
	int hard_rejects;
	int hazards;
	long long total_time;
} Simstats;

#endif
