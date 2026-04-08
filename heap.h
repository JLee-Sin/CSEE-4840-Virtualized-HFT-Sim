#ifndef _HEAP_H_
#define _HEAP_H_

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef void *(*HeapCmpFunc)(const void *a, const void *b);

typedef struct {
	int price;
	long long timestamp;
	int amount;
	int type; //1 = Ask 0 = Bid
} Order;

typedef struct {
	void **data;
	int size;
	int capacity;
	HeapCmpFunc cmp;
} Heap;

Order *create_order(int price, int amount, int type) {
	Order *o = malloc(sizeof(Order));
	o->price = price;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	o->timestamp = ts.tv_nsec;
	o->amount = amount;
	o->type = type;
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
		if(((Order *)a)->amount < ((Order *)b)->amount) {
			return (void *)a;
		} else if(((Order *)a)->amount == ((Order *)b)->amount) {
			if(((Order *)a)->timestamp < ((Order *)b)->timestamp) {
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
		if(((Order *)a)->amount > ((Order *)b)->amount) {
			return (void *)a;
		} else if(((Order *)a)->amount == ((Order *)b)->amount) {
			if(((Order *)a)->timestamp > ((Order *)b)->timestamp) {
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

static void check_for_trade(Heap *asks, Heap *bids) {
	if(asks->size == 0 || bids->size == 0) {
		return;
	}
	
	Order *bid = (Order *)peek(bids);
	Order *ask = (Order *)peek(asks);

	if(bid->price >= ask->price) {
		if(bid->amount == ask->amount) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			printf("A trade has been executed at %ld! Sold %d shares of AAA at $%d.\n",
				       ts.tv_nsec,
				       ask->amount,
				       bid->price
			);
			pop(bids);
			pop(asks);
		} else {
			if(bid->amount > ask->amount) {
				struct timespec ts;
				clock_gettime(CLOCK_MONOTONIC, &ts);
				printf("A partial fill has been executed at %ld! Sold %d shares of AAA at $%d. A bid for %d shares remains.\n",
						ts.tv_nsec,
						ask->amount,
					       	ask->price, 
						bid->amount - ask->amount
				);
				update(bids, bid->amount - ask->amount);
				pop(asks);
			} else {
				struct timespec ts;
				clock_gettime(CLOCK_MONOTONIC, &ts);
				printf("A partial fill has been executed at %ld! Sold %d shares of AAA at $%d. A ask of %d shares remains.\n",
						ts.tv_nsec,
						bid->amount,
					       	bid->price, 
						ask->amount - bid->amount
				);
				update(asks, ask->amount - bid->amount);
				pop(bids);
			}
		}
	}	
}

#endif
