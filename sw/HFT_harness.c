#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <signal.h>

#include "HFT_drivers.h"

#define HFT_ALL_LANES_MASK ((1u << HFT_NUM_LANES) - 1u)
#define HFT_STATE_IDLE     0
#define HFT_STATE_WRITE    1
#define HFT_STATE_DISPATCH 2
#define HFT_STATE_DONE     3

// Error macros
#define HFT_ERR_RESET (-ECONNRESET)

// Driver
int hft_sim_fd;

// Ctrl+C handling
static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int signo) {
    (void)signo;
    g_stop = 1;
}

// Internal Structs
typedef struct {
    FILE *lane_csv[HFT_NUM_LANES];   // One CSV stream per lane (see below correspondence)
    bool  lane_eof[HFT_NUM_LANES];   // True if EOF reached on that lane
} LaneCSVReader;

///////////////////////////////////////////////////////////////////////
// Helper Functions
///////////////////////////////////////////////////////////////////////

///////// Time/Sleep /////////
static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static int sleep_ms(unsigned ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000u;
    ts.tv_nsec = (long)(ms % 1000u) * 1000000l;
    while (nanosleep(&ts, &ts) != 0) {
        if (errno == EINTR) continue;
        return -errno;
    }
    return 0;
}

static int sleep_us(unsigned us) {
    struct timespec ts;
    ts.tv_sec  = us / 1000000u;
    ts.tv_nsec = (long)(us % 1000000u) * 1000l;
    while (nanosleep(&ts, &ts) != 0) {
        if (errno == EINTR) continue;
        return -errno;
    }
    return 0;
}

///////// CSV Helpers /////////
static void close_all_csvs(LaneCSVReader *r) {
    if (!r) return;

    // Close all CSVs
    for (int i = 0; i < HFT_NUM_LANES; i++) {
        if (r->lane_csv[i]) {
            fclose(r->lane_csv[i]);
            r->lane_csv[i] = NULL;
        }
        r->lane_eof[i] = false;
    }
}

static int open_all_csvs(LaneCSVReader *r, const char *data_dir) {
    if (!r || !data_dir) return -EINVAL;

    // All files that will be used
    static const char *lane_file[HFT_NUM_LANES] = {
        "AAPL.csv", "BSX.csv", "BUS.csv", "MMM.csv",
        "MSFT.csv", "SBUX.csv", "TUS.csv", "WMT.csv"
    };

    // Try to open CSV files
    for (int lane = 0; lane < HFT_NUM_LANES; lane++) {
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", data_dir, lane_file[lane]);

        // Try to open file
        r->lane_csv[lane] = fopen(path, "r");

        // If opening fails, close all files and print error message.
        if (!r->lane_csv[lane]) {
            fprintf(stderr, "ERROR: cannot open lane %d CSV '%s': %s\n",
                    lane, path, strerror(errno));
            close_all_csvs(r);
            return -ENOENT;
        }

        r->lane_eof[lane] = false;
    }
    return 0;
}

static void csv_rewind_all(LaneCSVReader *csv) {
    for (int i = 0; i < HFT_NUM_LANES; i++) {
        rewind(csv->lane_csv[i]);
        clearerr(csv->lane_csv[i]);
        csv->lane_eof[i] = false;
    }
}

///////// Order Dispatcher States /////////
// Get Status of Order Dispatcher
int hft_disp_get_status(int fd, struct hft_disp_status *st) {
    if (!st) return -EINVAL;
    if (ioctl(fd, HFT_IOC_DISP_GET_STATUS, st) < 0) return -errno;
    return 0;
}

// Wait for a specific state in the Order Dispatcher
int hft_disp_wait_state(int fd, uint32_t want_state, int timeout_ms, int poll_ms, bool abort_on_idle) {
    if (poll_ms <= 0) poll_ms = 1;
    uint64_t deadline = (timeout_ms < 0) ? 0 : (now_ms() + (uint64_t)timeout_ms);

    for (;;) {
        // Get state
        struct hft_disp_status st;
        int rc = hft_disp_get_status(fd, &st);
        if (rc) return rc;

        // Check for desire state
        if (st.state == want_state) return 0;

        // Check if board was reseted: Dispatcher went into IDLE all the sudden
        if (abort_on_idle && st.state == HFT_STATE_IDLE && want_state != HFT_STATE_IDLE)
            return HFT_ERR_RESET;

        // Check for timeout
        if (timeout_ms >= 0 && now_ms() >= deadline) return -ETIMEDOUT;
        (void)sleep_ms((unsigned)poll_ms);
    }
}

// Signals and wait until Order Dispatcher has transitioned to DISPATCHT
int hft_transition_to_dispatch(int fd, int timeout_ms) {
    // Check that dispatcher is in WRITE (otherwise DISPATCH pulse is ignored).
    int rc = hft_disp_wait_state(fd, HFT_STATE_WRITE, timeout_ms, 1, false);
    if (rc) return rc;

    // Signal transition
    rc = ioctl(fd, HFT_IOC_DISP_BEGIN_DISPATCH);
    if (rc < 0) return -errno;

    // Wait until DISPATCH is observed.
    return hft_disp_wait_state(fd, HFT_STATE_DISPATCH, timeout_ms, /*poll_ms=*/1, true);
}

// Signals and wait until Order Dispatcher has transitioned to IDLE
// This is once it has transitioned to DONE by itself
int hft_transition_done_to_idle(int fd, int timeout_ms) {
    int rc = hft_disp_wait_state(fd, HFT_STATE_DONE, timeout_ms, 1, false);
    if (rc) return rc;

    // Indicate to Order Dispatcher to transition to IDLE state
    rc = ioctl(fd, HFT_IOC_DISP_CLEAR_DONE);
    if (rc < 0) return -errno;

    return hft_disp_wait_state(fd, HFT_STATE_IDLE, timeout_ms, 1, false);
}

// Simple herlper fucntion to check if all FIFOs are full
static bool hft_all_fifos_full_mask(uint32_t full_mask) {
    return (full_mask & HFT_ALL_LANES_MASK) == HFT_ALL_LANES_MASK;
}

///////// Pushing Orders into FIFOs /////////
// Pushes an order into the specified lane (lane = fifo)
int hft_disp_push_order(int fd, uint32_t lane, const struct hft_disp_order *o) {
    if (!o) return -EINVAL;

    struct hft_disp_push_req req;
    memset(&req, 0, sizeof(req));
    req.lane  = lane;
    req.order = *o;

    if (ioctl(fd, HFT_IOC_DISP_PUSH_ORDER, &req) < 0) return -errno;
    return 0;
}

// Push that waits for lane ready (or until timeout).
int hft_disp_push_order_blocking(int fd, uint32_t lane, const struct hft_disp_order *o,
                            int timeout_ms, int poll_us) {
    if (poll_us <= 0) poll_us = 200; // 0.2ms default
    uint64_t deadline = (timeout_ms < 0) ? 0 : (now_ms() + (uint64_t)timeout_ms);

    for (;;) {
        int rc = hft_disp_push_order(fd, lane, o);
        if (rc == 0) return 0;

        // Typical transient errors from driver:
        //  -EAGAIN: not in WRITE state
        //  -EBUSY : lane not ready (FIFO full)
        if (rc != -EAGAIN && rc != -EBUSY) return rc;

        if (timeout_ms >= 0 && now_ms() >= deadline) return -ETIMEDOUT;
        (void)sleep_us((unsigned)poll_us);
    }
}

// Check if there is new order to push for specified lane
static int lane_csv_next_order(void *ctx, int lane, struct hft_disp_order *out){
    LaneCSVReader *r = (LaneCSVReader *)ctx;
    // Check lane reader is not empty
    if (!r || !out) return -EINVAL;
    // Check for null pointers
    if ((unsigned)lane >= HFT_NUM_LANES) return -EINVAL;
    // Check lane
    if (r->lane_eof[lane]) return 0;

    char line[256];

    // Loop until there is ususable data in a row
    for (;;) {
        // Read line in csv
        if (!fgets(line, sizeof(line), r->lane_csv[lane])) {
            r->lane_eof[lane] = true;
            return 0; // EOF
        }

        // Skip header or blank lines
        if (line[0] == '\n' || line[0] == '\r') continue;
        if (!strncmp(line, "Type,", 5)) continue;

        char type_s[16];
        unsigned price_u, qty_u;

        // Parse lines
        // Expected format: <BID/ASK>, <Price>, <Quantity>
        if (sscanf(line, " %15[^,],%u,%u", type_s, &price_u, &qty_u) != 3)
            return -EINVAL;

        // Map type string to bit value
        if (!strcmp(type_s, "ASK")) out->type = 0;
        else if (!strcmp(type_s, "BID")) out->type = 1;
        else return -EINVAL;

        // Range checks for price and quantity
        if (price_u > 0xFFFF) return -EINVAL;
        if (qty_u > 0x7FFF)  return -EINVAL;

        // Fill output struct
        out->price = (uint16_t)price_u;
        out->quantity = (uint16_t)qty_u;

        return 1; // successfuly produced an order
    }
}

// Callback: produce next order for a given lane.
// Return:
//   1  -> *out filled with next order
//   0  -> EOF/no-more-orders for that lane
//  <0  -> error
typedef int (*hft_next_order_fn)(void *ctx, int lane, struct hft_disp_order *out);

// Writes round-robin to fifo0-fifo7 until:
//   - all FIFOs are full, OR
//   - every lane's source is exhausted, OR
//   - timeout hits (timeout applies to overall loop; use -1 for no timeout)
int hft_write_orders_round_robin(int fd, hft_next_order_fn next_order, void *ctx, int timeout_ms){
    if (!next_order) return -EINVAL;

    uint64_t deadline = (timeout_ms < 0) ? 0 : (now_ms() + (uint64_t)timeout_ms);

    bool lane_done[HFT_NUM_LANES] = { false };

    for (;;) {
        // Stop if all lanes are done
        bool all_done = true;
        for (int i = 0; i < HFT_NUM_LANES; i++) all_done &= lane_done[i];
        if (all_done) return 0;

        struct hft_disp_status st;
        int rc = hft_disp_get_status(fd, &st);
        if (rc) return rc;

        // Stop if all FIFOs full
        if (hft_all_fifos_full_mask(st.full_mask)) return 0;

        // Check if board was reseted: dispatcher when back to IDLE
        if (st.state == HFT_STATE_IDLE) return HFT_ERR_RESET;

        // Check if Order Dispatcher in WRITE state
        if (st.state != HFT_STATE_WRITE)
            return -EAGAIN;

        for (int lane = 0; lane < HFT_NUM_LANES; lane++) {
            if (lane_done[lane]) continue;
            if (st.full_mask & (1u << lane)) continue;

            struct hft_disp_order o;
            int have = next_order(ctx, lane, &o);
            if (have < 0) return have;
            if (have == 0) { lane_done[lane] = true; continue; }

            rc = hft_disp_push_order_blocking(fd, (uint32_t)lane, &o,
                                         /*timeout_ms=*/2000,
                                         /*poll_us=*/200);
            if (rc) return rc;

            if (timeout_ms >= 0 && now_ms() >= deadline) return -ETIMEDOUT;

            // Refresh status to avoid pushing into lanes that just filled
            rc = hft_disp_get_status(fd, &st);
            if (rc) return rc;
            if (hft_all_fifos_full_mask(st.full_mask)) return 0;
        }
    }
}

///////// Reading Trade Logs /////////
// Get Trade log data
int hft_log_get_info(int fd, struct hft_log_info *li) {
    if (!li) return -EINVAL;
    if (ioctl(fd, HFT_IOC_LOG_GET_INFO, li) < 0) return -errno;
    return 0;
}

// Reads up to `max_entries` into `entries`.
// On success, *out_count is filled with the number read.
int hft_log_read_all(int fd, struct hft_log_entry *entries,
                       uint32_t max_entries, uint32_t *out_count, uint32_t *out_overflow) {
    if (!entries || !out_count) return -EINVAL;

    struct hft_log_info li;
    int rc = hft_log_get_info(fd, &li);
    if (rc) return rc;

    if (out_overflow) *out_overflow = li.overflow;

    uint32_t n = li.count;
    if (n > max_entries) n = max_entries;

    for (uint32_t i = 0; i < n; i++) {
        struct hft_log_entry le;
        memset(&le, 0, sizeof(le));
        le.index = i;

        if (ioctl(fd, HFT_IOC_LOG_READ_ENTRY, &le) < 0) return -errno;
        entries[i] = le;
    }

    *out_count = n;
    return 0;
}

// Prints specified mask for all lanes: fifo full, fifo empty, or engine idle
static void print_lane_mask(FILE *fp, const char *label, uint32_t mask) {
    fprintf(fp, "%s:", label);
    for (int lane = 0; lane < HFT_NUM_LANES; lane++) {
        fprintf(fp, " %d=%c", lane, (mask & (1u << lane)) ? '1' : '0');
    }
    fprintf(fp, "\n");
}

// Prints the state of the Dispatcher
static const char *disp_state_str(uint32_t state) {
    switch (state) {
        case HFT_STATE_IDLE:     return "IDLE";
        case HFT_STATE_WRITE:    return "WRITE";
        case HFT_STATE_DISPATCH: return "DISPATCH";
        case HFT_STATE_DONE:     return "DONE";
        default:                 return "UNKNOWN";
    }
}

// 
static void hft_print_progress_snapshot(FILE *fp, int fd) {
    struct hft_disp_status st;
    int rc_st = hft_disp_get_status(fd, &st);

    struct hft_log_info li;
    int rc_li = hft_log_get_info(fd, &li);

    if (rc_st == 0) {
        fprintf(fp, "[progress] Dispatcher state=%s (%u)\n", disp_state_str(st.state), st.state);
        print_lane_mask(fp, "[progress] FIFO empty_mask", st.empty_mask);
        print_lane_mask(fp, "[progress] FIFO full_mask ", st.full_mask);
        print_lane_mask(fp, "[progress] FIFO ready_mask", st.ready_mask);
    } else {
        fprintf(fp, "[progress] Dispatcher status unavailable (rc=%d)\n", rc_st);
    }

    if (rc_li == 0) {
        fprintf(fp, "[progress] Trade log count=%u overflow=%u trade_done=%u\n",
               li.count, li.overflow, li.trade_done);
        fprintf(fp, "[progress] Engines: all_idle=%u idle_mask=0x%08x\n",
               li.all_engines_idle, li.engine_idle_mask);
    } else if (rc_li == -EAGAIN) {
        fprintf(fp, "[progress] Trade logger info not ready yet (rc=%d)\n", rc_li);
    } else {
        fprintf(fp, "[progress] Trade logger info unavailable (rc=%d)\n", rc_li);
    }
}

// Checks that HFT_SIM is done trading by
// - Checking Order Dispatcher is the DONE state
// - All Heap Engines are in the IDLE state
static int hft_log_wait_trade_done(FILE *progress_fp, int fd, int timeout_ms, int poll_ms,
                                   struct hft_log_info *out_final){
    if (poll_ms <= 0) poll_ms = 1;

    uint64_t deadline = (timeout_ms < 0) ? 0 : (now_ms() + (uint64_t)timeout_ms);

    // Throttle printing so we don't spam the console.
    const uint64_t print_period_ms = 250;
    uint64_t next_print_ms = 0;

    for (;;) {
        // Handle logging being interrupted nicely
        if (g_stop) {
            if (progress_fp) {
                fprintf(progress_fp, "[progress] interrupted (SIGINT)\n");
                fflush(progress_fp);
            }
            return -EINTR;
        }

        // Detect if board was reseted: Dispatcher back to IDLE
        struct hft_disp_status st;
        int rc_st = hft_disp_get_status(fd, &st);
        if (rc_st) return rc_st;
        if (st.state == HFT_STATE_IDLE) return HFT_ERR_RESET;

        // Get trade log info
        struct hft_log_info li;
        int rc = hft_log_get_info(fd, &li);

        uint64_t t = now_ms();
        if (t >= next_print_ms) {
            if (progress_fp) {
                hft_print_progress_snapshot(progress_fp, fd);
                fflush(progress_fp);
            }
            next_print_ms = t + print_period_ms;
        }

        if (rc == 0) {
            if (li.trade_done) {
                if (out_final) *out_final = li;
                return 0;
            }
        } else if (rc != -EAGAIN) {
            // Real error
            return rc;
        }

        if (timeout_ms >= 0 && now_ms() >= deadline)
            return -ETIMEDOUT;

        (void)sleep_ms((unsigned)poll_ms);
    }
}

// Prints each trade log
static void hft_log_dump_entries(FILE *fp, const struct hft_log_entry *e, uint32_t n){
    for (uint32_t i = 0; i < n; i++) {
        fprintf(fp, "%u,0x%08x,0x%08x,0x%06x\n",
                i, e[i].word0, e[i].word1, (e[i].word2 & 0x003FFFFF));
    }
}

///////////////////////////////////////////////////////////////////////
// Main Function - Actual harness
// Lanes/FIFO corresponding to each symbol (from symbol_engine.sv):
// 0 - AAPL (aka APL)
// 1 - BSX
// 2 - BUS
// 3 - MMM
// 4 - MSFT (aka SFT)
// 5 - SBUX (aks BUX)
// 6 - TUS
// 7 - WMT
///////////////////////////////////////////////////////////////////////
int main(){
    // Install Ctrl+C handler so we can flush/close logs cleanly.
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    (void)sigaction(SIGINT, &sa, NULL);

    FILE *progress_fp = fopen("hft_progress.txt", "w");
    if (!progress_fp) {
        fprintf(stderr, "WARNING: could not open hft_progress.txt for writing: %s\n", strerror(errno));
    }
    // Change if data dir changes
    const char *data_dir = "../data";

    // Check for device drivers
    static const char filename[] = "/dev/hft_sim";
    if ( (hft_sim_fd = open(filename, O_RDWR)) == -1) {
        fprintf(stderr, "Error: could not open %s\n", filename);
        return -1;
    }
    printf("Starting HFT Simulator Harness.\n");

    // Get CSV files
    LaneCSVReader csv = {0};
    int rc = open_all_csvs(&csv, data_dir); // Error messages already handled
    if (rc) return 1;

    for (;;) {
        // On CTL+C
        if (g_stop) break;

        // Rewind CSV 
        csv_rewind_all(&csv);
        
        // Clear counter and overflow of Trade logs
        if (ioctl(hft_sim_fd, HFT_IOC_LOG_CLEAR) < 0) return -errno;
    
        // Transition Order Dispatcher to WRITE
        //if (ioctl(hft_sim_fd, HFT_IOC_DISP_BEGIN_WRITE) < 0) return -errno;
        rc = hft_disp_wait_state(hft_sim_fd, HFT_STATE_WRITE, -1, 10, false); // No timeout
        if (rc == HFT_ERR_RESET) { printf("Reset detected. Restarting.\n"); continue; }
        if (rc) { fprintf(stderr, "Error: wait for WRITE failed rc=%d\n", rc); return 1; }
    
        // Fill FIFOs round-robin from CSVs
        printf("Writing Data to Order Dispatcher.\n");
        rc = hft_write_orders_round_robin(hft_sim_fd, lane_csv_next_order, &csv, 30000);
        if (rc == HFT_ERR_RESET) { printf("Reset detected during write. Restarting.\n"); continue; }
        if (rc) { fprintf(stderr, "ERROR: write_orders_round_robin failed: %d\n", rc); return 1;}
    
        // Debug: Check state before start dispatching
        struct hft_disp_status st;
        hft_disp_get_status(hft_sim_fd, &st);
        fprintf(stderr, "Before DISPATCH: state=%u ready=0x%02x empty=0x%02x full=0x%02x\n",
                st.state, st.ready_mask, st.empty_mask, st.full_mask);
    
        // Transition Order Dispatcher to DISPATCH
        // hft_transition_to_dispatch(hft_sim_fd, 1000);
        rc = hft_disp_wait_state(hft_sim_fd, HFT_STATE_DISPATCH, -1, 10, true); // No timeout
        if (rc == HFT_ERR_RESET) { printf("Reset detected before dispatch. Restarting.\n"); continue; }
        if (rc) { fprintf(stderr, "Error: wait for DISPATCH failed rc=%d\n", rc); return 1; }
        printf("Virtualized HFT Simulator has started.\n");
        
        // Wait until trading is completely finished 
        struct hft_log_info final_li;
        rc = hft_log_wait_trade_done(progress_fp, hft_sim_fd, 600000, 2, &final_li);
        if (rc == HFT_ERR_RESET) { printf("Reset detected during dispatch. Restarting.\n"); continue; }
        if (rc == -EINTR) { fprintf(stderr, "Interrupted (Ctrl+C). Exiting cleanly.\n"); }
        if (rc) {fprintf(stderr, "ERROR: timed out / failed waiting for trade_done: %d\n", rc);}
    
        // Read all trade log entries 
        printf("Trading done.\n");
        printf("Trade log count (trades recorded): %u\n", final_li.count);
        printf("Trade log overflow: %u\n", final_li.overflow);
        uint32_t n = final_li.count;
        if (n > 1024) n = 1024; // safety (matches RTL depth)
        if (n == 0) {
            printf("No trades recorded.\n");
            close_all_csvs(&csv);
            return 0;
        }
    
        struct hft_log_entry *logbuf = calloc(n, sizeof(*logbuf));
        if (!logbuf) {
            fprintf(stderr, "ERROR: calloc failed\n");
            close_all_csvs(&csv);
            return 1;
        }
    
        uint32_t got = 0, overflow = 0;
        rc = hft_log_read_all(hft_sim_fd, logbuf, n, &got, &overflow);
        if (rc) {
            fprintf(stderr, "ERROR: hft_log_read_all failed: %d\n", rc);
            free(logbuf);
            close_all_csvs(&csv);
            return 1;
        }
    
        // Dump to stdout for now
        printf("Read back %u trade log entries (overflow=%u)\n", got, overflow);
        printf("index,word0,word1,word2_low22\n");
        hft_log_dump_entries(stdout, logbuf, got);
    
        free(logbuf);

        // For now, run once. 
        break;
    }

    // Clean up
    close_all_csvs(&csv);
    if (progress_fp) fclose(progress_fp);

    return 0;
}
