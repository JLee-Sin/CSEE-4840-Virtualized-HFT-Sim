# CSEE4840-Final_Project - A Simple HFT Simulator and Memory Management System on an FPGA

**Jayden Lee-Sin** (JCL2257) · **Carlos Espinoza** (CRE2121) · **Derrick Bassey** (DAB2266)

---

## Introduction

The goal of this project is to develop a high frequency trading (HFT) device on an FPGA which leverages virtualization to handle multiple trades simultaneously by dynamically allocating resources. In hardware, the FPGA handles matching asks and bids, allocating memory to each symbol being traded, and potential collisions. Meanwhile, the software component of this project is responsible for emulating the stream of information normally done via network in real HFT applications. In addition, this software harness collects data on the operations of hardware such as when a symbol is bought or sold, at what price, how fast this occurred, and more.

This cleanly breaks the project into four pieces:

- **The HFT System**
- **The Memory Management System**
- **The Hazard Management System**
- **The Software Harness**

---

## The HFT System

In a stock exchange, buyers and sellers are consistently reporting bids (the highest amount a buyer is willing to pay) and asks (the lowest price a seller is willing to accept). This makes it the duty of the exchange to match the best bid and best ask as fast as possible. While this can be done through software on a CPU, FPGAs specialized in these tasks are able to confirm and make trades at a much higher rate — hence the term high frequency trading.

To emulate this, we create two binary heaps implementing priority queues: a **maximum heap** containing all of the bids for a symbol, and a **minimum heap** containing all of the asks. The best bid and best ask become the root of each heap as quickly as possible. When the best bid is equal to or better than the best ask, a trade is made and the roots are removed and both heaps are reordered. If the best ask is higher than the best bid, both nodes remain in their heaps until a trade can be executed.

The software harness consistently adds additional values for both heaps, leading to the constant reordering of both heaps as the hardware attempts to find new trades. Both heaps need to support the following operations: pop (remove nodes), reorder, add elements, and peek (inspect the root to determine if a trade should be executed).

### Tie-Breaking with Timestamps

When the root of one of the heaps is equivalent to another node in the same heap, timestamps recorded at the time of submission are used to break the tie. The root is not only the minimum or maximum of the available nodes, but the *oldest* minimum or maximum — prioritizing buyers and sellers who submit their ask or bid first, as real trading systems do.

### Partial Fills

In real life, buyers and sellers often offer multiple shares at a time. When a buyer wants more shares than the seller is offering, a **partial fill** is executed. For example, if the best ask offers 3 shares at \$47 and the best bid wants 6 shares at \$47, the buyer purchases the 3 available shares, the requested amount is decreased from 6 to 3, and the best ask is removed from the minimum heap while the updated best bid remains in the maximum heap until a new trade can be executed. This also means the heaps must be capable of editing existing nodes.

---

## The Memory Management System

To add an additional layer of depth, we want to execute multiple trades at a single time for different symbols, so our exchange can process trades for both AAA and BBB simultaneously. This requires that each symbol has its own set of binary heaps and therefore its own space in the FPGA's memory.

Rather than preallocating pages in memory based on a fixed offset (which is wasteful), we pursue **virtualization**: each symbol believes it owns all of the available memory, but in reality a supervisor maps virtual addresses to physical addresses. As a symbol uses all of its physical memory, the supervisor assigns a new page; when an entire page is left empty, the supervisor removes it for dynamic reallocation.

### Translation Lookaside Buffer (TLB)

Converting from virtual to physical address by looking up the page table on every access essentially doubles access time, defeating the purpose of a speed-focused system. A small **TLB** (content-addressable memory cache of recently used translations) takes the virtual page number and returns the physical frame number in the same clock cycle, acting in parallel. Prioritizing TLB hit rate is critical, as a miss stalls the rest of the pipeline for a manual translation.

### Free-Frame Bitmap

A shift register where each bit represents a physical page in memory. Each time a new page is allocated, the system finds the current set bit and shifts it (shifting in a zero). When the bitmap is all zeros, the system is out of physical memory.

### Out-of-Memory Strategies

1. **Per-symbol page limit** — Prevents one symbol from consuming all physical memory.
2. **Overflow pool** — A reserved physical page shared between all symbols, acting as an emergency buffer while trades execute and free up memory.
3. **Hard reject** — The symbol refuses to accept any more asks or bids when the system has no remaining memory.


---

## The Hazard Management System

The hazard system handles hazards generated by the HFT system, the memory management system, and their interactions.

### HFT Hazards

The primary hazard is **read-after-write (RAW)**, which occurs when two operations targeting the same symbol overlap and the second reads a stale node value before the first finishes writing.

### Memory Management Hazards

**TLB coherence issues** arise when the TLB's virtual-to-physical mappings change. If the TLB holds an old mapping for one symbol and a new symbol tries to access that memory, it may overwrite the first symbol's memory or read an incorrect value.

### Cross-System Hazards

When the systems interact, hazards such as trades occurring on stale root nodes, the memory management system stalling a trade on the wrong symbol, or stalls cascading from a TLB miss can occur.

### Resolution

A **per-symbol stall** mechanism allows the system to retain speed for unaffected symbols while resolving hazards on problematic symbols at the cost of latency.

---

## The Software Harness

The software harness serves as the interface between the host and the FPGA hardware.

### Input

Data is passed to the hardware as binary encoding information such as the symbol, price, amount, whether the request is an ask or a bid, and the timestamp. The memory management system writes it into the page assigned to the specified symbol (creating a new page if none exists) and then allows the HFT system to handle insertion into the correct heap.

### Output

During simulation, each executed trade prints the symbol, price, amount, and execution time to the terminal. At the end of a simulation, the harness outputs:

- Number of trades executed per symbol
- Average price of each symbol for successful trades
- Total simulation time
- Number of reads and writes to memory
- Record of hazards that occurred during simulation

### Golden Model

As an additional component, a golden model of the system is implemented in software so the harness output can be used as a point of comparison for verification.

## Design Notes

### Bit Sizing of orders

- Type: 1 bit (Ask or Bid)
- Price: 16 bits (0 to 65536)
- Amount: 16 bits (0 to 65536)
- Symbol: 21 bits (3 letters, 7-bits each, defined by ASCII capital letters)

Timestamp is to be designated by the FPGA according to order in which they are received. Values range from 0 to 4294967296 (2^32).

### Sizing of Memory Elements

Given that each node is 86bits, the widest supported word size by BRAM that wastes the minimal amount of bits is 32:

40-bit words: 86/40 = 2.15 -> 3 words per node (120 bits, 34 unused)

32-bit words: 86/32 = 2.69 -> 3 words per node (96 bits, 10 unused)

20-bit words: 86/20 = 4.3  -> 5 words per node (100 bits, 14 wasted)

Each BRAM block holds 256 words, so:

256 words/3 words per node = 85 nodes per block

For cleaner addressing, we'll use 64 nodes per page, which results in 192 words per page. Assuming we reserve 10 blocks for all non-heap based operation, we keep 387 blocks for the heaps. This results in storing a total of 24,768 orders at a given time.

387 pages * 64 nodes per page = 24,768 total nodes

Choosing the closest number for clean address decoding, we can instead use 256 pages, resulting in:

256 pages * 64 nodes per page = 16,384 total nodes

Finally, as a way to manage a dominant symbol and handle out of memory events, we chose to (arbitrarily) limit the maximum number of pages a single symbol can inhabit to be half of this maximum page size or 128 pages and reserve the size a single page for overflow. 
