#ifndef _HEAP_H_
#define _HEAP_H_

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#define DEFAULT_MODE 1
#define DEFAULT_ORDERS 100
#define MAX_PRICE 100
#define MAX_AMOUNT 10
#define MAX_ORDERS 1000

typedef void *(*HeapCmpFunc)(const void *a, const void *b);

typedef struct {
	short price;
	uint32_t timestamp;
	short amount;
	int type; //1 = Ask 0 = Bid - This will be 1 bit in hardware
	char symbol[4]; //3 chars + null terminator
} Order;

typedef struct {
	void **data;
	int size;
	int capacity;
	HeapCmpFunc cmp;
} Heap;

Order *create_order(int price, int amount, int type, const char *symbol) {
	Order *o = malloc(sizeof(Order));
	o->price = price;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	o->timestamp = (uint32_t) ts.tv_nsec;
	o->amount = amount;
	o->type = type;
	strncpy(o->symbol, symbol, 3);
	o->symbol[3] = '\0';
	return o;
}

Heap *create_heap(int capacity, HeapCmpFunc cmp) {
	Heap *h = malloc(sizeof(Heap));
	h->data = malloc(sizeof(void *) * capacity);
	h->size = 0;
	h->capacity = capacity;
	h->cmp = cmp;
	return h;
}

static int rand_range(int min, int max) {
	return min + rand() % (max - min + 1);
}

static void swap(void **a, void **b) {
	void *tmp = *a;
       	*a = *b;
       	*b = tmp;
}

static void sift_up(Heap *h, int i) {
	while (i > 0) {
		int parent = (i - 1) / 2;
		if (h->cmp(h->data[i], h->data[parent]) == h->data[i]) {
			swap(&h->data[i], &h->data[parent]);
			i = parent;
		} else {
			break;
		}
	}
}

static void sift_down(Heap *h, int i) {
	while (1) {
		int best = i;
		int left = 2 * i + 1;
		int right = 2 * i + 2;

		if(left < h->size && h->cmp(h->data[left], h->data[best]) == h->data[left]) {
			best = left;
		}
		if(right < h->size && h->cmp(h->data[right], h->data[best]) == h->data[right]) {
			best = right;
		}
		if(best != i) {
			swap(&h->data[i], &h->data[best]);
			i = best;
		} else {
			break;
		}
	}
}

void update(Heap *h, int new_amount) {
	((Order *)h->data[0])->amount = new_amount;
}

void push(Heap *h, void *val) {
	if(h->size == h->capacity) {
		h->capacity *= 2;
		h->data = realloc(h->data, sizeof(void *) * h->capacity);
	}
	h->data[h->size] = val;
	sift_up(h, h->size);
	h->size++;
}

void *pop(Heap *h) {
	void *top = h->data[0];
	h->data[0] = h->data[--h->size];
	sift_down(h, 0);
	return top;
}

void *peek(Heap *h) {
	return h->data[0];
}

void free_order(Order *o) {
	free(o);
}

void free_heap(Heap *h) {
	free(h->data);
	free(h);
}

void *min_cmp(const void *a, const void *b) {
	if(((Order *)a)->price < ((Order *)b)->price) {
		return (void *)a;
	} else if(((Order *)a)->price == ((Order *)b)->price) {
		if(((Order *)a)->timestamp < ((Order *)b)->timestamp) {
			return (void *)a;
		} else if(((Order *)a)->timestamp == ((Order *)b)->timestamp) {
			if(((Order *)a)->amount > ((Order *)b)->amount) {
				return (void *)a;
			} else {
				return (void *)b;
			}
		} else {
			return (void *)b;
		}
	} else {
		return (void *)b;
	}
}

void *max_cmp(const void *a, const void *b) {
	if(((Order *)a)->price > ((Order *)b)->price) {
		return (void *)a;
	} else if(((Order *)a)->price == ((Order *)b)->price) {
		if(((Order *)a)->timestamp < ((Order *)b)->timestamp) {
			return (void *)a;
		} else if(((Order *)a)->timestamp == ((Order *)b)->timestamp) {
			if(((Order *)a)->amount > ((Order *)b)->amount) {
				return (void *)a;
			} else {
				return (void *)b;
			}
		} else {
			return (void *)b;
		}
	} else {
		return (void *)b;
	}
}

static int check_for_trade(Heap *asks, Heap *bids) {
	if(asks->size == 0 || bids->size == 0) {
		return 0;
	}
	
	Order *bid = (Order *)peek(bids);
	Order *ask = (Order *)peek(asks);

	if(bid->price >= ask->price) {
		if(bid->amount == ask->amount) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			printf("A trade has been executed at %d! Sold %d shares of %s at $%d.\n",
				       (uint32_t) ts.tv_nsec,
				       ask->amount,
				       ask->symbol,
				       bid->price
			);
			pop(bids);
			pop(asks);
			return 1;
		} else {
			if(bid->amount > ask->amount) {
				struct timespec ts;
				clock_gettime(CLOCK_MONOTONIC, &ts);
				printf("A partial fill has been executed at %d! Sold %d shares of %s at $%d. A bid for %d shares remains.\n",
						(uint32_t) ts.tv_nsec,
						ask->amount,
						ask->symbol,
					       	bid->price, 
						bid->amount - ask->amount
				);
				update(bids, bid->amount - ask->amount);
				pop(asks);
				return 1;
			} else {
				struct timespec ts;
				clock_gettime(CLOCK_MONOTONIC, &ts);
				printf("A partial fill has been executed at %d! Sold %d shares of %s at $%d. A ask of %d shares remains.\n",
						(uint32_t) ts.tv_nsec,
						bid->amount,
						ask->symbol,
					       	bid->price, 
						ask->amount - bid->amount
				);
				update(asks, ask->amount - bid->amount);
				pop(bids);
				return 1;
			}
		}
	} else {
		return 0;
	}	
}

#endif
