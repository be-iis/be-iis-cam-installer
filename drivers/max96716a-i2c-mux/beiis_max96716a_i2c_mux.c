// SPDX-License-Identifier: GPL-2.0-only
/*
 * BE-IIS MAX96716A / MAX96717 dual-link I2C address translator.
 *
 * Both remote IMX708 sensors use physical address 0x1a. The Raspberry Pi
 * kernel 6.12 shipped for this target has the I2C-ATR headers, but does not
 * export the I2C-ATR core symbols to external modules. This module therefore
 * implements the small, fixed mapping required by this HAT locally:
 *
 *   child bus A, remote 0x1a -> MAX96717-A alias 0x54
 *   child bus B, remote 0x1a -> MAX96717-B alias 0x55
 *
 * The MAX96716A reverse control channels remain enabled simultaneously. A
 * unique alias makes the two sensors independently accessible even though
 * they share their physical address.
 *
 * This is only the I2C control plane. It does not configure video, CSI,
 * media entities, overlays, or camera drivers.
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
#define BEIIS_LINK_A_ALIAS		0x54
#define BEIIS_LINK_B_ALIAS		0x55
#define BEIIS_PADDING_ADDR		0x51
#define BEIIS_PADDING_VALUE		0xae

/* MAX96716A registers used by the upstream MAX96716A driver. */
#define MAX96716_REG1			0x0001
#define MAX96716_REG1_DIS_REM_CC_A	BIT(4)
#define MAX96716_REG3			0x0003
#define MAX96716_REG3_DIS_REM_CC_B	BIT(2)

/* MAX96717 address-translation register pair, slot 0. */
#define MAX96717_I2C_SRC		0x0042
#define MAX96717_I2C_DST		0x0043

struct beiis_max96716a_i2c;

struct beiis_i2c_channel {
	struct i2c_adapter adap;
	struct beiis_max96716a_i2c *bridge;
	u8 alias;
	u32 link;
	struct mutex xfer_lock;
};

struct beiis_max96716a_i2c {
	struct i2c_client *des;
	struct beiis_i2c_channel channel[BEIIS_NUM_LINKS];
};

static int parent_bus = 11;
module_param(parent_bus, int, 0444);
MODULE_PARM_DESC(parent_bus, "Parent I2C adapter number (default: 11)");

static ushort des_addr = 0x28;
module_param(des_addr, ushort, 0444);
MODULE_PARM_DESC(des_addr, "MAX96716A 7-bit I2C address (default: 0x28)");

static ushort serializer_addr = 0x40;
module_param(serializer_addr, ushort, 0444);
MODULE_PARM_DESC(serializer_addr,
		 "Temporary MAX96717 address while configuring each link (default: 0x40)");

static struct i2c_adapter *beiis_parent;
static struct i2c_client *beiis_des;
static struct beiis_max96716a_i2c *beiis_bridge;

static int beiis_xfer(struct i2c_adapter *adapter, struct i2c_msg *msgs, int num)
{
	int ret;

	ret = i2c_transfer(adapter, msgs, num);
	if (ret == num)
		return 0;

	return ret < 0 ? ret : -EIO;
}

static int beiis_write_byte_reg(struct beiis_max96716a_i2c *bridge, u16 addr,
				u8 reg, u8 value)
{
	u8 data[] = { reg, value };
	struct i2c_msg msg = {
		.addr = addr,
		.flags = 0,
		.len = sizeof(data),
		.buf = data,
	};

	return beiis_xfer(bridge->des->adapter, &msg, 1);
}

static int beiis_write_reg(struct beiis_max96716a_i2c *bridge, u16 addr,
			   u16 reg, u8 value)
{
	u8 data[] = { reg >> 8, reg & 0xff, value };
	struct i2c_msg msg = {
		.addr = addr,
		.flags = 0,
		.len = sizeof(data),
		.buf = data,
	};

	return beiis_xfer(bridge->des->adapter, &msg, 1);
}

static int beiis_read_reg(struct beiis_max96716a_i2c *bridge, u16 reg, u8 *value)
{
	u8 address[] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[] = {
		{
			.addr = bridge->des->addr,
			.flags = 0,
			.len = sizeof(address),
			.buf = address,
		},
		{
			.addr = bridge->des->addr,
			.flags = I2C_M_RD,
			.len = 1,
			.buf = value,
		},
	};

	return beiis_xfer(bridge->des->adapter, msgs, ARRAY_SIZE(msgs));
}

/*
 * These sequences are the manually verified way to reach the still-default
 * serializer address 0x40 on this BE-IIS board. They are used only while
 * programming one serializer's private translation slot.
 */
static int beiis_select_link(struct beiis_max96716a_i2c *bridge, u32 link)
{
	int ret;

	/* The known-good manual scripts set the fixed 2K padding first. */
	ret = beiis_write_byte_reg(bridge, BEIIS_PADDING_ADDR,
				   0x01, BEIIS_PADDING_VALUE);
	if (ret)
		return ret;

	switch (link) {
	case BEIIS_LINK_A:
		ret = beiis_write_reg(bridge, bridge->des->addr, 0x0f00, 0x01);
		if (ret)
			return ret;
		return beiis_write_reg(bridge, bridge->des->addr, 0x0010, 0x31);

	case BEIIS_LINK_B:
		ret = beiis_write_reg(bridge, bridge->des->addr, 0x0001, 0x02);
		if (ret)
			return ret;
		ret = beiis_write_reg(bridge, bridge->des->addr, 0x0011, 0x0b);
		if (ret)
			return ret;
		return beiis_write_reg(bridge, bridge->des->addr, 0x0010, 0x31);

	default:
		return -EINVAL;
	}
}

static int beiis_program_alias(struct beiis_max96716a_i2c *bridge,
			       struct beiis_i2c_channel *channel)
{
	int ret;

	ret = beiis_select_link(bridge, channel->link);
	if (ret)
		return ret;

	ret = beiis_write_reg(bridge, serializer_addr, MAX96717_I2C_SRC,
			      channel->alias << 1);
	if (ret)
		return ret;

	ret = beiis_write_reg(bridge, serializer_addr, MAX96717_I2C_DST,
			      BEIIS_REMOTE_IMX708_ADDR << 1);
	if (ret)
		return ret;

	/* Keep the second translation slot disabled, matching the manual scripts. */
	ret = beiis_write_reg(bridge, serializer_addr, 0x0044, 0x00);
	if (ret)
		return ret;
	return beiis_write_reg(bridge, serializer_addr, 0x0045, 0x00);
}

/*
 * The reference MAX96716A driver enables both remote control channels. With
 * different serializer aliases, a transaction is forwarded only through its
 * matching link.
 */
static int beiis_enable_remote_control_channels(struct beiis_max96716a_i2c *bridge)
{
	u8 value;
	int ret;

	ret = beiis_read_reg(bridge, MAX96716_REG1, &value);
	if (ret)
		return ret;
	ret = beiis_write_reg(bridge, bridge->des->addr, MAX96716_REG1,
			      value & ~MAX96716_REG1_DIS_REM_CC_A);
	if (ret)
		return ret;

	ret = beiis_read_reg(bridge, MAX96716_REG3, &value);
	if (ret)
		return ret;
	return beiis_write_reg(bridge, bridge->des->addr, MAX96716_REG3,
			       value & ~MAX96716_REG3_DIS_REM_CC_B);
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
	 * The child buses intentionally expose the physical sensor address.
	 * Translate every message atomically before it reaches I2C-11.
	 */
	mutex_lock(&channel->xfer_lock);
	for (i = 0; i < num; i++) {
		original_addrs[i] = msgs[i].addr;
		if (msgs[i].addr != BEIIS_REMOTE_IMX708_ADDR) {
			ret = -ENXIO;
			goto restore;
		}
		msgs[i].addr = channel->alias;
	}

	ret = i2c_transfer(channel->bridge->des->adapter, msgs, num);

restore:
	while (i--)
		msgs[i].addr = original_addrs[i];
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

	if (addr != BEIIS_REMOTE_IMX708_ADDR)
		return -ENXIO;

	return i2c_smbus_xfer(channel->bridge->des->adapter, channel->alias,
			      flags, read_write, command, size, data);
}

static u32 beiis_child_functionality(struct i2c_adapter *adapter)
{
	struct beiis_i2c_channel *channel = adapter->algo_data;

	return i2c_get_functionality(channel->bridge->des->adapter);
}

static const struct i2c_algorithm beiis_child_algorithm = {
	.master_xfer = beiis_child_master_xfer,
	.smbus_xfer = beiis_child_smbus_xfer,
	.functionality = beiis_child_functionality,
};

static int beiis_add_child_adapter(struct beiis_max96716a_i2c *bridge, u32 link,
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
	channel->adap.dev.parent = &bridge->des->dev;
	channel->adap.retries = bridge->des->adapter->retries;
	channel->adap.timeout = bridge->des->adapter->timeout;
	channel->adap.quirks = bridge->des->adapter->quirks;

	return i2c_add_adapter(&channel->adap);
}

static int __init beiis_max96716a_i2c_init(void)
{
	int ret;

	beiis_parent = i2c_get_adapter(parent_bus);
	if (!beiis_parent)
		return -ENODEV;

	if (!i2c_check_functionality(beiis_parent, I2C_FUNC_I2C)) {
		ret = -EOPNOTSUPP;
		goto put_adapter;
	}

	beiis_des = i2c_new_dummy_device(beiis_parent, des_addr);
	if (IS_ERR(beiis_des)) {
		ret = PTR_ERR(beiis_des);
		beiis_des = NULL;
		goto put_adapter;
	}

	beiis_bridge = devm_kzalloc(&beiis_des->dev, sizeof(*beiis_bridge),
				    GFP_KERNEL);
	if (!beiis_bridge) {
		ret = -ENOMEM;
		goto unregister_des;
	}
	beiis_bridge->des = beiis_des;

	/* Install both distinct serializer aliases before enabling both CC links. */
	beiis_bridge->channel[BEIIS_LINK_A].link = BEIIS_LINK_A;
	beiis_bridge->channel[BEIIS_LINK_A].alias = BEIIS_LINK_A_ALIAS;
	beiis_bridge->channel[BEIIS_LINK_B].link = BEIIS_LINK_B;
	beiis_bridge->channel[BEIIS_LINK_B].alias = BEIIS_LINK_B_ALIAS;

	ret = beiis_program_alias(beiis_bridge,
				  &beiis_bridge->channel[BEIIS_LINK_A]);
	if (ret) {
		dev_err(&beiis_des->dev, "Link-A alias setup failed: %d\\n", ret);
		goto unregister_des;
	}
	ret = beiis_program_alias(beiis_bridge,
				  &beiis_bridge->channel[BEIIS_LINK_B]);
	if (ret) {
		dev_err(&beiis_des->dev, "Link-B alias setup failed: %d\\n", ret);
		goto unregister_des;
	}

	ret = beiis_enable_remote_control_channels(beiis_bridge);
	if (ret) {
		dev_err(&beiis_des->dev,
			"enabling both reverse-control channels failed: %d\\n", ret);
		goto unregister_des;
	}

	ret = beiis_add_child_adapter(beiis_bridge, BEIIS_LINK_A,
				      BEIIS_LINK_A_ALIAS);
	if (ret)
		goto unregister_des;

	ret = beiis_add_child_adapter(beiis_bridge, BEIIS_LINK_B,
				      BEIIS_LINK_B_ALIAS);
	if (ret)
		goto del_link_a;

	dev_info(&beiis_des->dev,
		 "BE-IIS aliases ready: Link A 0x1a->0x54, Link B 0x1a->0x55\n");
	return 0;

del_link_a:
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_A].adap);
unregister_des:
	i2c_unregister_device(beiis_des);
	beiis_des = NULL;
put_adapter:
	i2c_put_adapter(beiis_parent);
	beiis_parent = NULL;
	return ret;
}

static void __exit beiis_max96716a_i2c_exit(void)
{
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_B].adap);
	i2c_del_adapter(&beiis_bridge->channel[BEIIS_LINK_A].adap);
	i2c_unregister_device(beiis_des);
	i2c_put_adapter(beiis_parent);
}

module_init(beiis_max96716a_i2c_init);
module_exit(beiis_max96716a_i2c_exit);

MODULE_DESCRIPTION("BE-IIS MAX96716A dual-link I2C address translator");
MODULE_AUTHOR("BE-IIS");
MODULE_LICENSE("GPL");
