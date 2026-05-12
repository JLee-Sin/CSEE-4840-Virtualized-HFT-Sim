#ifndef _HFT_DRIVER_H
#define _HFT_DRIVER_H
#include <linux/ioctl.h>
#include <linux/types.h>
#define HFT_NUM_LANES 8

// Structs for Interacting with Dispatcher
struct hft_disp_order {
    __u8  type;      // 0 or 1
    __u16 price;     // 16 bits
    __u16 quantity;  // low 15 bits
};

struct hft_disp_push_req {
    __u32 lane;  // 0..7
    struct hft_disp_order order;
};

struct hft_disp_status {
    __u32 state;       // IDLE/WRITE/DISPATCH/DONE
    __u32 ready_mask;  // per-lane write ready
    __u32 empty_mask;  // per-lane fifo empty
    __u32 full_mask;   // per-lane fifo full
};

// Structs for Interacting with Trade Logger
struct hft_log_info {
    __u32 count;
    __u32 overflow;
    __u32 engine_idle_mask;
    __u32 all_engines_idle;
    __u32 trade_done;
};

struct hft_log_entry {
    __u32 index;   // input
    __u32 word0;   // output: [31:0]
    __u32 word1;   // output: [63:32]
    __u32 word2;   // output: [85:64] in low 22 bits
};

// Communication with Order Dispatcher / Trade Logger
#define HFT_DRIVERS_MAGIC 'h'

#define HFT_IOC_DISP_BEGIN_WRITE     _IO (HFT_DRIVERS_MAGIC, 1)
#define HFT_IOC_DISP_BEGIN_DISPATCH  _IO (HFT_DRIVERS_MAGIC, 2)
#define HFT_IOC_DISP_CLEAR_DONE      _IO (HFT_DRIVERS_MAGIC, 3)
#define HFT_IOC_DISP_PUSH_ORDER      _IOW(HFT_DRIVERS_MAGIC, 4, struct hft_disp_push_req)
#define HFT_IOC_DISP_GET_STATUS      _IOR(HFT_DRIVERS_MAGIC, 5, struct hft_disp_status)

#define HFT_IOC_LOG_GET_INFO         _IOR (HFT_DRIVERS_MAGIC, 6, struct hft_log_info)
#define HFT_IOC_LOG_READ_ENTRY       _IOWR(HFT_DRIVERS_MAGIC, 7, struct hft_log_entry)
#define HFT_IOC_LOG_CLEAR            _IO  (HFT_DRIVERS_MAGIC, 8)

#endif
