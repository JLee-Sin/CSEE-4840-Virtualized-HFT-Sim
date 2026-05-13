//////////////////////////////////////////////////////////////////////////////////
// Engineers: Carlos Espinoza
// Create Date: 04/07/2026
// Project Name: Virtualized High Frequence Trading (HFT) Simulator
// Design Name: Device Drivers  
// Description:
//      This is the device drivers for the Virtualize HFT Device. 
//
// Revision: 05/08/2026
//////////////////////////////////////////////////////////////////////////////////

#include <linux/module.h>
#include <linux/init.h>
#include <linux/errno.h>
#include <linux/version.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/types.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include "HFT_drivers.h"

#define DRIVER_NAME "hft_sim"

// Device registers 
#define REG_CONTROL     0x00
#define REG_STATUS      0x04
#define REG_PUSH_BASE   0x08
#define REG_PUSH(n)     (REG_PUSH_BASE + 4 * (n)) // We are using 32-bit words
#define REG_LOG_INFO    0x28
#define REG_LOG_CMD     0x2C
#define REG_LOG_DATA0   0x30
#define REG_LOG_DATA1   0x34
#define REG_ADDR(x)     (dev.virtbase + (x))

// Control and status bit defs
#define CTRL_BEGIN_WRITE                BIT(0)
#define CTRL_BEGIN_DISPATCH             BIT(1)
#define CTRL_CLEAR_DONE                 BIT(2)
#define STATUS_STATE_MASK               0x00000003
#define STATUS_READY_MASK               0x000003FC
#define STATUS_EMPTY_MASK               0x0003FC00
#define STATUS_FULL_MASK                0x03FC0000
#define STATUS_READY_SHIFT              2
#define STATUS_EMPTY_SHIFT              10
#define STATUS_FULL_SHIFT               18
#define HFT_STATE_IDLE                  0
#define HFT_STATE_WRITE                 1
#define HFT_STATE_DISPATCH              2
#define HFT_STATE_DONE                  3
#define LOG_INFO_OVERFLOW_BIT           0
#define LOG_INFO_DATA_VALID_BIT         1
#define LOG_INFO_COUNT_SHIFT            2
#define LOG_INFO_COUNT_MASK             (0x7FFFu << LOG_INFO_COUNT_SHIFT) /* 15b count for depth 16384 */
#define LOG_INFO_ENGINE_IDLE_SHIFT      17
#define LOG_INFO_ENGINE_IDLE_MASK       (0xFFu << LOG_INFO_ENGINE_IDLE_SHIFT)
#define LOG_INFO_ALL_ENGINES_IDLE_BIT   25
#define LOG_INFO_TRADE_DONE_BIT         26

// Information about HFT_SIM device
struct hft_dev {
    struct resource res;            // Resource: registers
    void __iomem *virtbase;         // Where registers can be accessed in memory
    struct mutex lock;
} dev;

/////////////////////////////////////////////////////////////////////// 
// Helper Functions 
///////////////////////////////////////////////////////////////////////

// Constructs Orders to match what Order Dispatcher expects:
// [type [31]| price [30:15] | quantity [14:0]]
static inline __u32 hft_disp_pack_order_word(const struct hft_disp_order *o){
    return (((__u32)(o->type & 0x1)) << 31) |
           (((__u32)(o->price & 0xFFFF)) << 15) |
           ((__u32)(o->quantity & 0x7FFF));
}

// Write Order to specific buffer in hardware 
static int hft_disp_push_order_hw(__u32 lane, const struct hft_disp_order *o){
    __u32 raw, ready_mask;

    // Check lane of buffer we are writing to
    if (lane >= 8)
        return -EINVAL;

    // Check that type and quantity fit 
    if (o->type > 1 || o->quantity > 0x7FFF)
        return -EINVAL;

    // Check dipatcher status and lanes are ready to write
    raw = ioread32(REG_ADDR(REG_STATUS));
    if ((raw & STATUS_STATE_MASK) != HFT_STATE_WRITE)
        return -EAGAIN;
    ready_mask = (raw & STATUS_READY_MASK) >> STATUS_READY_SHIFT;
    if (!(ready_mask & BIT(lane)))
        return -EBUSY;

    // Write order word into PUSH lane register
    iowrite32(hft_disp_pack_order_word(o), REG_ADDR(REG_PUSH(lane)));
    return 0;
}

// Read trade log
static int hft_log_read_entry_hw(struct hft_log_entry *entry){
    __u32 status, state;
    __u32 info, count;
    int timeout_us = 1000;

    // Check dispatcher STATUS for DONE state
    status = ioread32(REG_ADDR(REG_STATUS));
    state  = status & STATUS_STATE_MASK;
    if (state != HFT_STATE_DONE)
        return -EAGAIN;

    // Read LOG_INFO for: count, overflow, data_valid, and engine idle bits
    info  = ioread32(REG_ADDR(REG_LOG_INFO));
    count = (info & LOG_INFO_COUNT_MASK) >> LOG_INFO_COUNT_SHIFT;
    if (entry->index >= count)
        return -EINVAL;

    // Issue trade log read request: bit1=read_req, bits[...]=index<<2
    iowrite32(BIT(1) | (entry->index << 2), REG_ADDR(REG_LOG_CMD));

    // Wait for valid data:
    // LOG_INFO[1] = data_valid
    do {
        info = ioread32(REG_ADDR(REG_LOG_INFO));
        if (info & BIT(LOG_INFO_DATA_VALID_BIT))
            break;
        udelay(1);
    } while (--timeout_us);
    if (!(info & BIT(LOG_INFO_DATA_VALID_BIT)))
        return -ETIMEDOUT;

    // Read trade logs payload words
    entry->word0 = ioread32(REG_ADDR(REG_LOG_DATA0));
    entry->word1 = ioread32(REG_ADDR(REG_LOG_DATA1));

    return 0;
}

/////////////////////////////////////////////////////////////////////// 
// User API 
///////////////////////////////////////////////////////////////////////

// Handle ioctl() calls from user
static long hft_ioctl(struct file *f, unsigned int cmd, unsigned long arg){
    void __user *user_arg = (void __user *)arg;
    struct hft_disp_push_req req;
    struct hft_disp_status st;
    struct hft_log_info li;
    struct hft_log_entry le;
    __u32 disp_status_raw;
    __u32 disp_state;
    __u32 log_info_raw;
    long ret = 0;

    mutex_lock(&dev.lock);

    // Determine what operation to perform 
    switch (cmd) {
        case HFT_IOC_DISP_BEGIN_WRITE:{
            // Write dispatcher CONTROL: begin_write pulse
            iowrite32(CTRL_BEGIN_WRITE, REG_ADDR(REG_CONTROL));
            break;
        }
            
        case HFT_IOC_DISP_BEGIN_DISPATCH:{
            // Write dispatcher CONTROL: begin_dispatch pulse
            iowrite32(CTRL_BEGIN_DISPATCH, REG_ADDR(REG_CONTROL));
            break;
        }
            
        case HFT_IOC_DISP_CLEAR_DONE:{
            // Write dispatcher CONTROL: clear_done pulse
            iowrite32(CTRL_CLEAR_DONE, REG_ADDR(REG_CONTROL));
            break;
        }
            
        case HFT_IOC_LOG_CLEAR:{
            // Write LOG_CMD: clear pulse (bit0)
            iowrite32(BIT(0), REG_ADDR(REG_LOG_CMD));
            break;
        }
    
        case HFT_IOC_DISP_PUSH_ORDER:{
            if (copy_from_user(&req, user_arg, sizeof(req))) {
                ret = -EFAULT;
                break;
            }
    
            ret = hft_disp_push_order_hw(req.lane, &req.order);
            break;
        }
    
        case HFT_IOC_DISP_GET_STATUS: {
            // Read dispatcher status
            disp_status_raw = ioread32(REG_ADDR(REG_STATUS));
            pr_info("HFT REG_STATUS raw=0x%08x\n", disp_status_raw);
        
            // Unpack signals
            st.state      = disp_status_raw & STATUS_STATE_MASK;
            st.ready_mask = (disp_status_raw & STATUS_READY_MASK) >> STATUS_READY_SHIFT;
            st.empty_mask = (disp_status_raw & STATUS_EMPTY_MASK) >> STATUS_EMPTY_SHIFT;
            st.full_mask  = (disp_status_raw & STATUS_FULL_MASK)  >> STATUS_FULL_SHIFT;
        
            if (copy_to_user(user_arg, &st, sizeof(st)))
                ret = -EFAULT;
            break;
        }
        
        case HFT_IOC_LOG_GET_INFO: {
            // Probe: allow read regardless of dispatcher state so we can see
            // engine_idle_mask / all_engines_idle / trade_done while the
            // dispatcher is stuck in DISPATCH. count may be stale until DONE,
            // but the engine status bits come straight from the HW and are
            // always valid.
            log_info_raw = ioread32(REG_ADDR(REG_LOG_INFO));
            li.overflow         = !!(log_info_raw & BIT(LOG_INFO_OVERFLOW_BIT));
            li.count            = (log_info_raw & LOG_INFO_COUNT_MASK) >> LOG_INFO_COUNT_SHIFT;
            li.engine_idle_mask = (log_info_raw & LOG_INFO_ENGINE_IDLE_MASK) >> LOG_INFO_ENGINE_IDLE_SHIFT;
            li.all_engines_idle = !!(log_info_raw & BIT(LOG_INFO_ALL_ENGINES_IDLE_BIT));
            li.trade_done       = !!(log_info_raw & BIT(LOG_INFO_TRADE_DONE_BIT));

            pr_info(DRIVER_NAME ": LOG_INFO raw=0x%08x state=%u count=%u eng_idle_mask=0x%02x all_idle=%u trade_done=%u\n",
                    log_info_raw,
                    ioread32(REG_ADDR(REG_STATUS)) & STATUS_STATE_MASK,
                    li.count, li.engine_idle_mask, li.all_engines_idle, li.trade_done);

            if (copy_to_user(user_arg, &li, sizeof(li)))
                ret = -EFAULT;
            break;
        }
    
        case HFT_IOC_LOG_READ_ENTRY:{
            if (copy_from_user(&le, user_arg, sizeof(le))) {
                ret = -EFAULT;
                break;
            }
    
            ret = hft_log_read_entry_hw(&le);
            if (ret)
                break;
    
            if (copy_to_user(user_arg, &le, sizeof(le)))
                ret = -EFAULT;
            break;
        }
        
        default:{
            ret = -EINVAL;
            break;
        }
    }

    mutex_unlock(&dev.lock);
    return ret;
}

// The operations our device knows how to do 
static const struct file_operations hft_fops = {
    .owner          = THIS_MODULE,
    .unlocked_ioctl = hft_ioctl,
};

// Information about our device for the "misc" framework -- like a char dev
static struct miscdevice hft_misc_device = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DRIVER_NAME,
    .fops  = &hft_fops,
};

/////////////////////////////////////////////////////////////////////// 
// Driver Probe and Remove
///////////////////////////////////////////////////////////////////////

// Initialization code: get resources (registers) and display a welcome message
static int __init hft_probe(struct platform_device *pdev){
    int ret;

    pr_info(DRIVER_NAME ": probe called for %s\n", dev_name(&pdev->dev));

    mutex_init(&dev.lock);

    ret = misc_register(&hft_misc_device);
    if (ret) {
        pr_err(DRIVER_NAME ": misc_register failed: %d\n", ret);
        return ret;
    }

    ret = of_address_to_resource(pdev->dev.of_node, 0, &dev.res);
    if (ret) {
        pr_err(DRIVER_NAME ": of_address_to_resource failed: %d\n", ret);
        ret = -ENOENT;
        goto out_deregister;
    }

    pr_info(DRIVER_NAME ": resource start=%pa size=%lu\n",
        &dev.res.start, (unsigned long)resource_size(&dev.res));

    if (!request_mem_region(dev.res.start, resource_size(&dev.res), DRIVER_NAME)) {
        pr_err(DRIVER_NAME ": request_mem_region failed\n");
        ret = -EBUSY;
        goto out_deregister;
    }

    dev.virtbase = of_iomap(pdev->dev.of_node, 0);
    if (!dev.virtbase) {
        pr_err(DRIVER_NAME ": of_iomap failed\n");
        ret = -ENOMEM;
        goto out_release_mem;
    }

    pr_info(DRIVER_NAME ": probe successful\n");
    return 0;
out_release_mem:
    release_mem_region(dev.res.start, resource_size(&dev.res));
out_deregister:
    misc_deregister(&hft_misc_device);
    return ret;
}

// Clean-up code: release resources
static int hft_remove(struct platform_device *pdev){
    iounmap(dev.virtbase);
    release_mem_region(dev.res.start, resource_size(&dev.res));
    misc_deregister(&hft_misc_device);
    return 0;
}

/////////////////////////////////////////////////////////////////////// 
// Driver Probe and Remove
///////////////////////////////////////////////////////////////////////

// Which "compatible" string(s) to search for in the Device Tree 
#ifdef CONFIG_OF
static const struct of_device_id hft_of_match[] = {
    { .compatible = "csee4840,hft_sim-1.0" },
    { },
};
MODULE_DEVICE_TABLE(of, hft_of_match);
#endif

// Information for registering ourselves as a "platform" driver 
static struct platform_driver hft_driver = {
    .driver = {
        .name = DRIVER_NAME,
        .owner = THIS_MODULE,
        .of_match_table = of_match_ptr(hft_of_match),
    },
    .remove = __exit_p(hft_remove),
};

// Called when the module is loaded: set things up 
static int __init hft_init(void){
    pr_info(DRIVER_NAME ": init\n");
    return platform_driver_probe(&hft_driver, hft_probe);
}

// Calball when the module is unloaded: release resources 
static void __exit hft_exit(void){
    platform_driver_unregister(&hft_driver);
    pr_info(DRIVER_NAME ": exit\n");
}

module_init(hft_init);
module_exit(hft_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Carlos Espinoza");
MODULE_DESCRIPTION("HFT_SIM Driver");