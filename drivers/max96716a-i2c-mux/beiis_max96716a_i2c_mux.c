// SPDX-License-Identifier: GPL-2.0-only
/*
 * BE-IIS dual-link I2C router and address translator.
 *
 * The control-plane scripts configure the two physical GMSL links and the
 * MAX96717 translations:
 *
 *   Link A: IMX708 0x1a is exposed upstream as alias 0x52
 *   Link B: IMX708 0x1a is exposed upstream as alias 0x53
 *
 * This module deliberately does not configure the MAX96716A/MAX96717. It
 * creates two Linux I2C child buses. Before every transfer it selects the
 * matching physical MAX96716A link, then translates native IMX708 address
 * 0x1a to the already configured serializer alias.
 *
 * This is only the I2C control plane. It does not configure CSI, media,
 * overlays, camera drivers or video streaming.
 */
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>

#define BEIIS_LINK_A			0
#define BEIIS_LINK_B			1
#define BEIIS_NUM_LINKS			2
#define BEIIS_REMOTE_IMX708_ADDR	0x1a
#define BEIIS_DES_ADDR			0x28

/*
 * Link selection writes are the verified manual sequences from
 * init-gmsl-link-a.sh and init-gmsl-link-b.sh.  The scripts must have
 * configured serializer power/reset and aliases before this module is used.
 */

struct beiis_i2c_bridge;

struct beiis_i2c_channel {
	struct i2c_adapter adap;
	struct beiis_i2c_bridge *bridge;
	u8 alias;
	u32 link;
	struct mutex xfer_lock;
};

struct beiis_i2c_bridge {
	struct i2c_adapter *parent;
	struct beiis_i2c_channel channel[BEIIS_NUM_LINKS];
};

static int parent_bus = 11;
module_param(parent_bus, int, 0444);
MODULE_PARM_DESC(parent_bus, "Parent I2C adapter number (default: 11)");

static ushort alias_a = 0x52;
module_param(alias_a, ushort, 0444);
MODULE_PARM_DESC(alias_a, "Link-A MAX96717 sensor alias (default: 0x52)");

static ushort alias_b = 0x53;
module_param(alias_b, ushort, 0444);
MODULE_PARM_DESC(alias_b, "Link-B MAX96717 sensor alias (default: 0x53)");

static struct beiis_i2c_bridge *beiis_bridge;

/* Write one 16-bit MAX96716A register through the parent bus. */
static int beiis_des_write(struct beiis_i2c_bridge *bridge, u16 reg, u8 value)
{
	u8 data[] = { reg >> 8, reg & 0xff, value };
	struct i2c_msg msg = {
		.addr = BEIIS_DES_ADDR,
		.flags = 0,
		.len = sizeof(data),
		.buf = data,
	};
	int ret;

	ret = i2c_transfer(bridge->parent, &msg, 1);
	return ret == 1 ? 0 : (ret < 0 ? ret : -EIO);
}

/*
 * The MAX96716A has one upstream reverse-I2C path.  It must be pointed at
 * the requested physical GMSL link before the translated sensor transfer.
 * The channel mutex keeps selection and the following transfer atomic with
 * respect to the other child bus.
 */
static int beiis_select_link(struct beiis_i2c_channel *channel)
{
	struct beiis_i2c_bridge *bridge = channel->bridge;
	int ret;

	if (channel->link == BEIIS_LINK_A) {
		ret = beiis_des_write(bridge, 0x0f00, 0x01);
		if (ret)
			return ret;
		return beiis_des_write(bridge, 0x0010, 0x31);
	}

	ret = beiis_des_write(bridge, 0x0001, 0x02);
	if (ret)
		return ret;
	ret = beiis_des_write(bridge, 0x0011, 0x0b);
	if (ret)
		return ret;
	return beiis_des_write(bridge, 0x0010, 0x31);
}

static int beiis_child_master_xfer(struct i2c_adapter *adapter,
				   struct i2c_msg *msgs, int num)
{
	struct beiis_i2c_channel *channel = adapter->algo_data;
	u16 *original_addrs;
	int ret;
	int i;

	if (num <= 0)
		return -EINVAL;

	original_addrs = kmalloc_array(num, sizeof(*original_addrs), GFP_KERNEL);
	if (!original_addrs)
		return -ENOMEM;

	/*
	 * The two child buses intentionally expose the real IMX708 address.
	 * Rewrite every transfer to the unique MAX96717 alias on I2C-11.
	 */
	mutex_lock(&channel->xfer_lock);
	ret = beiis_select_link(channel);
	if (ret)
		goto unlock;

	for (i = 0; i < num; i++) {
		original_addrs[i] = msgs[i].addr;
		if (msgs[i].addr != BEIIS_REMOTE_IMX708_ADDR) {
			ret = -ENXIO;
			goto restore;
		}
		msgs[i].addr = channel->alias;
	}

	ret = i2c_transfer(channel->bridge->parent, msgs, num);

restore:
	while (i--)
		msgs[i].addr = original_addrs[i];
unlock:
	mutex_unlock(&channel->xfer_lock);
	kfree(original_addrs);

	return ret;
}

static s32 beiis_child_smbus_xfer(struct i2c_adapter *adapter, u16 addr,
				  unsigned short flags, char read_write,
				  u8 command, int size,
				  union i2c_smbus_data *data)
{
	struct beiis_i2c_channel *channel = adapter->algo_data;

	s32 ret;

	if (addr != BEIIS_REMOTE_IMX708_ADDR)
		return -ENXIO;

	mutex_lock(&channel->xfer_lock);
	ret = beiis_select_link(channel);
	if (!ret)
		ret = i2c_smbus_xfer(channel->bridge->parent, channel->alias,
				     flags, read_write, command, size, data);
	mutex_unlock(&channel->xfer_lock);

	return ret;
}

static u32 beiis_child_functionality(struct i2c_adapter *adapter)
{
	struct beiis_i2c_channel *channel = adapter->algo_data;

	return i2c_get_functionality(channel->bridge->parent);
}

static const struct i2c_algorithm beiis_child_algorithm = {
	.master_xfer = beiis_child_master_xfer,
	.smbus_xfer = beiis_child_smbus_xfer,
	.functionality = beiis_child_functionality,
};

static int beiis_add_child_adapter(struct beiis_i2c_bridge *bridge, u32 link,
				   u8 alias)
{
	struct beiis_i2c_channel *channel = &bridge->channel[link];

	channel->bridge = bridge;
	channel->alias = alias;
	channel->link = link;
	mutex_init(&channel->xfer_lock);

	snprintf(channel->adap.name, sizeof(channel->adap.name),
		 "BE-IIS GMSL Link %c", link == BEIIS_LINK_A ? 'A' : 'B');
	channel->adap.owner = THIS_MODULE;
	channel->adap.algo = &beiis_child_algorithm;
	channel->adap.algo_data = channel;
	channel->adap.dev.parent = &bridge->parent->dev;
	channel->adap.retries = bridge->parent->retries;
	channel->adap.timeout = bridge->parent->timeout;
	channel->adap.quirks = bridge->parent->quirks;

	return i2c_add_adapter(&channel->adap);
}

static int __init beiis_i2c_bridge_init(void)
{
	int ret;

	beiis_bridge = kzalloc(sizeof(*beiis_bridge), GFP_KERNEL);
	if (!beiis_bridge)
		return -ENOMEM;

	beiis_bridge->parent = i2c_get_adapter(parent_bus);
	if (!beiis_bridge->parent) {
		ret = -ENODEV;
		goto free_bridge;
	}

	if (!i2c_check_functionality(beiis_bridge->parent, I2C_FUNC_I2C)) {
		ret = -EOPNOTSUPP;
		goto put_adapter;
	}

	if (alias_a > 0x7f || alias_b > 0x7f || alias_a == alias_b) {
		ret = -EINVAL;
		goto put_adapter;
	}

	ret = beiis_add_child_adapter(beiis_bridge, BEIIS_LINK_A, alias_a);
	if (ret)
		goto put_adapter;

	ret = beiis_add_child_adapter(beiis_bridge, BEIIS_LINK_B, alias_b);
	if (ret)
		goto del_link_a;

	pr_info("beiis-i2c: Link A 0x1a->0x%02x, Link B 0x1a->0x%02x\n",
		alias_a, alias_b);
	return 0;

del_link_a:
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_A].adap);
put_adapter:
	i2c_put_adapter(beiis_bridge->parent);
free_bridge:
	kfree(beiis_bridge);
	beiis_bridge = NULL;
	return ret;
}

static void __exit beiis_i2c_bridge_exit(void)
{
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_B].adap);
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_A].adap);
	i2c_put_adapter(beiis_bridge->parent);
	kfree(beiis_bridge);
	beiis_bridge = NULL;
}

module_init(beiis_i2c_bridge_init);
module_exit(beiis_i2c_bridge_exit);

MODULE_DESCRIPTION("BE-IIS dual-link I2C router and address translator");
MODULE_AUTHOR("BE-IIS");
MODULE_LICENSE("GPL");
