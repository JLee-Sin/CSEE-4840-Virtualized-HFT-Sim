#include <stdio.h>
#include <time.h>
#include <string.h>
#include "heap.h"
#define DEFAULT_MODE 1
#define DEFAULT_ORDERS 100

static void automatic_execution(int orders) {
  	Heap *asks = create_heap(10, min_cmp);
  	Heap *bids = create_heap(10, max_cmp);

  	Order **order_list = malloc(sizeof(Order *) * orders);
  	for(int i = 0; i < orders; i++) {
    		order_list[i] = create_order(rand_range(1, 100), rand_range(1, 10), rand_range(0, 1));
		if(order_list[i]->type) {
			push(asks, &order_list[i]);
			printf("Ask Submitted; Price: $%d, Amount: %d, Timestamp: %lld\n", order_list[i]->price, order_list[i]->amount, order_list[i]->timestamp);
			check_for_trade(asks, bids);	
		} else {
			push(bids, &order_list[i]);
			printf("Bid Submitted; Price: $%d, Amount: %d, Timestamp: %lld\n", order_list[i]->price, order_list[i]->amount, order_list[i]->timestamp);	
			check_for_trade(asks, bids);
		}
  	}

	for(int i = 0; i < orders; i++) {
		free_order(order_list[i]);
	}
	free(order_list);

	free_heap(asks);
	free_heap(bids);
}

static void manual_execution() {
	//TODO: Implement manual execution: manual should use scanf to recieve order details, then execute trades if necessary after every order is received
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
