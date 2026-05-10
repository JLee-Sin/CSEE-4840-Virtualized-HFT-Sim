#ifndef _HFT_DRIVER_H
#define _HFT_DRIVER_H

#include <linux/ioctl.h>
#include <linux/types.h>

// Structs
struct hft_order {
    __u8  type;      // 0 or 1
    __u16 price;     // 16 bits */
    __u16 quantity;  // use only low 15 bits
};

struct hft_push_req {
    __u32 lane;         // 0..7
    struct hft_order order;
};

struct hft_status {
    __u32 state;
    __u32 ready_mask;
    __u32 empty_mask;
    __u32 full_mask;
};

struct hft_log_info {
    __u32 count;
    __u32 overflow;
};

struct hft_log_entry {
    __u32 index;   // input: which log entry to read
    __u32 word0;   // output: bits [31:0]
    __u32 word1;   // output: bits [63:32]
    __u32 word2;   // output: bits [85:64] in low 22 bits
};

// Communication with Order Dispatcher
#define HFT_DRIVERS_MAGIC 'h'
// Communication with Order Dispatcher / Trade Log
#define HFT_DRIVERS_MAGIC 'h'
#define HFT_IOC_BEGIN_WRITE      _IO(HFT_DRIVERS_MAGIC, 1)
#define HFT_IOC_BEGIN_DISPATCH   _IO(HFT_DRIVERS_MAGIC, 2)
#define HFT_IOC_CLEAR_DONE       _IO(HFT_DRIVERS_MAGIC, 3)
#define HFT_IOC_PUSH_ORDER       _IOW(HFT_DRIVERS_MAGIC, 4, struct hft_push_req)
#define HFT_IOC_GET_STATUS       _IOR(HFT_DRIVERS_MAGIC, 5, struct hft_status)
#define HFT_IOC_GET_LOG_INFO     _IOR(HFT_DRIVERS_MAGIC, 6, struct hft_log_info)
#define HFT_IOC_READ_LOG_ENTRY   _IOWR(HFT_DRIVERS_MAGIC, 7, struct hft_log_entry)
#define HFT_IOC_CLEAR_LOG        _IO(HFT_DRIVERS_MAGIC, 8)

#endif
