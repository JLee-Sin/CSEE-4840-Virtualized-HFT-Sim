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
#include "HFT_drivers.h"

#define DRIVER_NAME "HFT_SIM"

// Device registers 
#define REG_CONTROL      0x00
#define REG_STATUS       0x04
#define REG_PUSH_BASE    0x08
#define REG_PUSH(n)      (REG_PUSH_BASE + 4 * (n)) // We are using 32-bit words
#define REG_ADDR(x)      (dev.virtbase + (x))

// Control and status bit defs
#define CTRL_BEGIN_WRITE     BIT(0)
#define CTRL_BEGIN_DISPATCH  BIT(1)
#define CTRL_CLEAR_DONE      BIT(2)
#define STATUS_STATE_MASK   0x00000003
#define STATUS_READY_MASK   0x000003FC
#define STATUS_EMPTY_MASK   0x0003FC00
#define STATUS_FULL_MASK    0x03FC0000
#define STATUS_READY_SHIFT  2
#define STATUS_EMPTY_SHIFT  10
#define STATUS_FULL_SHIFT   18
#define HFT_STATE_IDLE       0
#define HFT_STATE_WRITE      1
#define HFT_STATE_DISPATCH   2
#define HFT_STATE_DONE       3

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
static inline __u32 pack_dispatch_order(const struct hft_order *o){
    return (((__u32)(o->type & 0x1)) << 31) |
           (((__u32)(o->price & 0xFFFF)) << 15) |
           ((__u32)(o->quantity & 0x7FFF));
}

// Write control signal for Order Dispatcher
static inline void hft_write_control(__u32 bits){
    iowrite32(bits, REG_ADDR(REG_CONTROL));
}

// Reads status signal from Order Dispatcher
static inline __u32 hft_read_status_raw(void){
    return ioread32(REG_ADDR(REG_STATUS));
}

// Write Order to specific buffer in hardware 
static int hft_push_order_hw(__u32 lane, const struct hft_order *o){
    __u32 raw, ready_mask;

    // Check lane of buffer we are writing to
    if (lane >= 8)
        return -EINVAL;

    // Check that type and quantity fit 
    if (o->type > 1 || o->quantity > 0x7FFF)
        return -EINVAL;

    // Check that dipatcher and lanse is ready to write
    raw = hft_read_status_raw();
    if ((raw & STATUS_STATE_MASK) != HFT_STATE_WRITE)
        return -EAGAIN;
    ready_mask = (raw & STATUS_READY_MASK) >> STATUS_READY_SHIFT;
    if (!(ready_mask & BIT(lane)))
        return -EBUSY;

    // Write to buffer
    iowrite32(pack_dispatch_order(o), REG_ADDR(REG_PUSH(lane)));
    return 0;
}

/////////////////////////////////////////////////////////////////////// 
// User API 
///////////////////////////////////////////////////////////////////////

// Handle ioctl() calls from user
static long hft_ioctl(struct file *f, unsigned int cmd, unsigned long arg){
    void __user *user_arg = (void __user *)arg;
    struct hft_push_req req;
    struct hft_status st;
    __u32 raw;
    long ret = 0;

    mutex_lock(&dev.lock);

    // 
    switch (cmd) {
    case HFT_IOC_BEGIN_WRITE:
        hft_write_control(CTRL_BEGIN_WRITE);
        break;

    case HFT_IOC_BEGIN_DISPATCH:
        hft_write_control(CTRL_BEGIN_DISPATCH);
        break;

    case HFT_IOC_CLEAR_DONE:
        hft_write_control(CTRL_CLEAR_DONE);
        break;

    case HFT_IOC_PUSH_ORDER:
        if (copy_from_user(&req, user_arg, sizeof(req))) {
            ret = -EFAULT;
            break;
        }

        ret = hft_push_order_hw(req.lane, &req.order);
        break;

    case HFT_IOC_GET_STATUS:
        raw = hft_read_status_raw();
    
        st.state      = raw & STATUS_STATE_MASK;
        st.ready_mask = (raw & STATUS_READY_MASK) >> STATUS_READY_SHIFT;
        st.empty_mask = (raw & STATUS_EMPTY_MASK) >> STATUS_EMPTY_SHIFT;
        st.full_mask  = (raw & STATUS_FULL_MASK)  >> STATUS_FULL_SHIFT;
    
        if (copy_to_user(user_arg, &st, sizeof(st)))
            ret = -EFAULT;
        break;

    default:
        ret = -EINVAL;
        break;
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
    mutex_init(&dev.lock);
    ret = misc_register(&hft_misc_device);
    if (ret)
        return ret;
    ret = of_address_to_resource(pdev->dev.of_node, 0, &dev.res);
    if (ret) {
        ret = -ENOENT;
        goto out_deregister;
    }
    if (!request_mem_region(dev.res.start, resource_size(&dev.res), DRIVER_NAME)) {
        ret = -EBUSY;
        goto out_deregister;
    }
    dev.virtbase = of_iomap(pdev->dev.of_node, 0);
    if (!dev.virtbase) {
        ret = -ENOMEM;
        goto out_release_mem;
    }
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
    { .compatible = "csee4840,hft-sim-1.0" },
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