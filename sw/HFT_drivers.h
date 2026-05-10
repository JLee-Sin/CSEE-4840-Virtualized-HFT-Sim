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

// Communication with Order Dispatcher
#define HFT_DRIVERS_MAGIC 'h'
#define HFT_IOC_BEGIN_WRITE      _IO(HFT_DRIVERS_MAGIC, 1)
#define HFT_IOC_BEGIN_DISPATCH   _IO(HFT_DRIVERS_MAGIC, 2)
#define HFT_IOC_CLEAR_DONE       _IO(HFT_DRIVERS_MAGIC, 3)
#define HFT_IOC_PUSH_ORDER       _IOW(HFT_DRIVERS_MAGIC, 4, struct hft_push_req)
#define HFT_IOC_GET_STATUS       _IOR(HFT_DRIVERS_MAGIC, 5, struct hft_status)

#endif
