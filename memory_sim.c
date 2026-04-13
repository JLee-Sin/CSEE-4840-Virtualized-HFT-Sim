#include <stdio.h>
#include <time.h>
#include <string.h>
#include "mmu.h"

static void automatic_execution(int orders) {
	Exchange *ex = create_exchange(16);
	MemoryManager *mm = create_memory_manager();
	SimStats stats = {0};

	const char *symbols[] = {"AAA", "BBB", "CCC", "DDD"};
	int num_symbols = 4;

	Order **order_list = malloc(sizeof(Order *) * orders);
	for(int i = 0; i < orders; i++) {
		const char *symbol = symbols[rand_range(0, num_symbols - 1)];
		order_list[i] = create_order(
				rand_range(1, MAX_PRICE),
			       	rand_range(1, MAX_AMOUNT),
			       	rand_range(0, 1),
			       	symbol);
		OrderBook *ob = find_or_create_book(ex, symbol);
		int sym_id = 0;
		for(int j = 0; j < ex->cnt; j++) {
			if(strcmp(ex->books[j]->symbol, symbol) == 0) {
				sym_id = j;
				break;
			}
		}
		
		if(order_list[i]->type) {
			printf("Ask Submitted for %s; Price: $%d, Amount %d, Timestamp: %d\n",
				       	symbol,
					order_list[i]->price,
					order_list[i]->amount,
					order_list[i]->timestamp);
		} else {
			printf("Bid Submitted for %s; Price: $%d, Amount %d, Timestamp: %d\n",
				       	symbol,
					order_list[i]->price,
					order_list[i]->amount,
					order_list[i]->timestamp);
		}

		if (mem_aware_insert(ob, mm, order_list[i], sym_id, &stats)) {
			while(check_for_trade_multi(ob, &stats)) {
				ob->trades++;
				post_trade_cleanup(mm, ob);
			}
		}

		trim(ob->asks, mm, ob);
		trim(ob->bids, mm, ob);
	}

	print_sim_stats(ex, mm, &stats);

	for(int i = 0; i < orders; i++) {
		free_order(order_list[i]);
	}
	free(order_list);
	free_exchange(ex);
	free(mm);
}

static void manual_execution() {
	//TODO
	printf("This still needs to be done!");
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
