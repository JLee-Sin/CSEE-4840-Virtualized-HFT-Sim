#include <stdio.h>
#include <time.h>
#include <string.h>
#include "heap.h"

static void automatic_execution(int orders) {
  	Heap *asks = create_heap(10, min_cmp);
  	Heap *bids = create_heap(10, max_cmp);

	int trades = 0;

  	Order **order_list = malloc(sizeof(Order *) * orders);
  	for(int i = 0; i < orders; i++) {
    		order_list[i] = create_order(rand_range(1, MAX_PRICE), rand_range(1, MAX_AMOUNT), rand_range(0, 1));
		if(order_list[i]->type) {
			push(asks, order_list[i]);
			printf("Ask Submitted; Price: $%d, Amount: %d, Timestamp: %lld\n", order_list[i]->price, order_list[i]->amount, order_list[i]->timestamp);
			if(check_for_trade(asks, bids)) {
				trades++;
			}	
		} else {
			push(bids, order_list[i]);
			printf("Bid Submitted; Price: $%d, Amount: %d, Timestamp: %lld\n", order_list[i]->price, order_list[i]->amount, order_list[i]->timestamp);	
			if(check_for_trade(asks, bids)) {
				trades++;
			}	
		}
  	}

	printf("Trades executed: %d\n", trades);

	for(int i = 0; i < orders; i++) {
		free_order(order_list[i]);
	}
	free(order_list);

	free_heap(asks);
	free_heap(bids);
}

static void manual_execution() {
	Heap *asks = create_heap(10, min_cmp);
	Heap *bids = create_heap(10, max_cmp);

	int trades = 0;
	int orders = 0;

	char order;
	int price;
	int amount;
	char type[1000];

	Order **order_list = malloc(sizeof(Order *) * MAX_ORDERS);
	while(1) {
		if(orders >= 1000) {
			printf("Maximum number of orders received, ending simulation\n");
			if(check_for_trade(asks, bids)) {
				trades++;
			}
			break;
		}
		printf("Would you like to submit an order? (Y/N)\n");
		scanf(" %c", &order);
		while (getchar() != '\n');
		if(order == 'Y') {
			printf("Please submit an order in the format (ask/bid), (price), (amount)\n");
			scanf("%s %d %d", type, &price, &amount);
			if(strcmp(type, "Ask") == 0 || strcmp(type, "ask") == 0) {
				order_list[orders] = create_order(price, amount, 1);
				push(asks, order_list[orders]);
				orders++;		
			} else if(strcmp(type, "Bid") == 0 || strcmp(type, "bid") == 0) {
				order_list[orders] = create_order(price, amount, 0);
				push(bids, order_list[orders]);
				orders++;
			} else {
				printf("Please specify ask or bid\n");
			}
			if(check_for_trade(asks, bids)) {
				trades++;
			}
		} else if(order == 'N') { 
			printf("Ending simulation\n");
			if(check_for_trade(asks, bids)) {
				trades++;
			}
			break;
		} else {
			printf("Please submit Y or N\n");
		}
		if(check_for_trade(asks, bids)) {
			trades++;
		}
	}

	printf("Trades executed: %d\n", trades);

	for(int i = 0; i < orders; i++) {
		free_order(order_list[i]);
	}
	free(order_list);

	free_heap(asks);
	free_heap(bids);
}

int main(int argc, char* argv[]) {
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
