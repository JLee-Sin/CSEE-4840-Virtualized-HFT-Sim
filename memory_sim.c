#include <stdio.h>
#include <time.h>
#include <string.h>
#include "mmu.h"

void free_node_memory(struct MemoryManager *mm, struct OrderBook *ob, struct SimStats *stats) {
	if (ob->mem.nodes_in_curr_page > 0) {
		ob->mem.nodes_in_curr_page--;
		if (ob->mem.page_count > 0) {
			int frame = translate(ob, ob->mem.page_count - 1, stats);
			if (frame >= 0) {
				mm->frames[frame].node_count--;
				if (mm->frames[frame].node_count == 0) {
					free_frame(mm, ob, ob->mem.page_count - 1, stats);
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
}

static void automatic_execution(int orders) {
	Exchange *ex = create_exchange(16);
	MemoryManager *mm = create_memory_manager();
	SimStats stats = {0};

	const char *symbols[] = {"AAA", "BBB", "CCC", "DDD", "EEE", "FFF"};
	int num_symbols = 6;

	Order **order_list = malloc(sizeof(Order *) * orders);
	for(int i = 0; i < orders; i++) {
		const char *symbol = symbols[rand_range(0, num_symbols - 1)];
		order_list[i] = create_order(
				rand_range(1, MAX_PRICE),
			       	rand_range(1, MAX_AMOUNT),
			       	rand_range(0, 1),
			       	symbol);
		OrderBook *ob = find_or_create_book(ex, symbol, mm, &stats);
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
				post_trade_cleanup(mm, ob, &stats);
			}
		}	
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
	Exchange *ex = create_exchange(16);
	MemoryManager *mm = create_memory_manager();
	SimStats stats = {0};

	int orders = 0;
	char order;
	int price;
	int amount;
	char type[16];
	char symbol[8];
	
	Order **order_list = malloc(sizeof(Order *) * MAX_ORDERS);

	while (1) {
		if (orders >= MAX_ORDERS) {
			printf("Maximum number of orders received, ending simulation\n");
			break;
		}

		printf("Would you like to submit an order? (Y/N)\n");
		scanf(" %c", &order);
		while (getchar() != '\n');
		if (order == 'Y' || order == 'y') {
			printf("Format: (ask/bid) (symbol) (price) (amount)\n");
			scanf("%s %s %d %d", type, symbol, &price, &amount);
			while (getchar() != '\n');
			symbol[3] = '\0';
			int is_ask = -1;
			
			if (strcmp(type, "Ask") == 0 || strcmp(type, "ask") == 0) {
				is_ask = 1;
			} else if (strcmp(type, "Bid") == 0 || strcmp(type, "bid") == 0) {
				is_ask = 0;
			} 
			
			if (is_ask < 0) {
				printf("Please specify ask or bid\n");
				continue;
			}

			order_list[orders] = create_order(price, amount, is_ask, symbol);
			OrderBook *ob = find_or_create_book(ex, symbol, mm, &stats);

			int sym_id = 0;
			for (int j = 0; j < ex->cnt; j++) {
				if (strcmp(ex->books[j]->symbol, symbol) == 0) {
					sym_id = j;
					break;
				}
			}

			if (is_ask) {
				printf("Ask Submitted: %s — Price: $%d, Amount: %d, Timestamp: %u\n",
					symbol, price, amount, order_list[orders]->timestamp);
			} else {
				printf("Bid Submitted: %s — Price: $%d, Amount: %d, Timestamp: %u\n",
					symbol, price, amount, order_list[orders]->timestamp);
			}

			if (mem_aware_insert(ob, mm, order_list[orders], sym_id, &stats)) {
				while (check_for_trade_multi(ob, &stats)) {
					ob->trades++;
					post_trade_cleanup(mm, ob, &stats);
				}
			}
			orders++;

		} else if (order == 'N' || order == 'n') {
			printf("Ending simulation\n");
			break;
		} else {
			printf("Please submit Y or N\n");
		}
	}

	print_sim_stats(ex, mm, &stats);

	for (int i = 0; i < orders; i++) {
		free_order(order_list[i]);
	}
	
	free(order_list);
	free_exchange(ex);
	free(mm);
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
