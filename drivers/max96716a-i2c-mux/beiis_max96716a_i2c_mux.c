// SPDX-License-Identifier: GPL-2.0-only
/*
 * BE-IIS MAX96716A / MAX96717 I2C Address Translator.
 *
 * The two remote IMX708 sensors both use address 0x1a. A normal I2C mux
 * cannot make those equal addresses coexist on one upstream control channel.
 *
 * This module uses the Linux I2C-ATR helper. It creates one child bus per
 * GMSL link. When a downstream I2C device is added, I2C-ATR allocates a
 * unique local alias. The attach callback programs that alias into the
 * corresponding MAX96717 address-translation slot.
 *
 * It is deliberately only a control-plane helper: no CSI, media graph,
 * overlay or video-pipe configuration is performed here.
 */
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/i2c-atr.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/property.h>

#define BEIIS_LINK_A			0
#define BEIIS_LINK_B			1
#define BEIIS_NUM_LINKS			2
#define BEIIS_MAX_XLATES_PER_LINK	2

/*
 * I2C-ATR must receive an alias pool from the device fwnode. These aliases
 * are local MAX96717 source addresses; 0x54..0x57 are unused on this HAT.
 * They intentionally differ from the physical IMX708 address (0x1a).
 */
static const u32 beiis_alias_pool[] = { 0x54, 0x55, 0x56, 0x57 };
static const struct property_entry beiis_atr_properties[] = {
	PROPERTY_ENTRY_U32_ARRAY("i2c-alias-pool", beiis_alias_pool),
	{ }
};
static const struct software_node beiis_atr_swnode = {
	.name = "beiis-max96716a-atr",
	.properties = beiis_atr_properties,
};

/* MAX96716A registers used by the upstream MAX96716A driver. */
#define MAX96716_REG1			0x0001
#define MAX96716_REG1_DIS_REM_CC_A	BIT(4)
#define MAX96716_REG3			0x0003
#define MAX96716_REG3_DIS_REM_CC_B	BIT(2)

/* MAX96717 address-translation register pairs. */
#define MAX96717_I2C_SRC(slot)		(0x0042 + (slot) * 2)
#define MAX96717_I2C_DST(slot)		(0x0043 + (slot) * 2)

struct beiis_max96716a_atr {
	struct i2c_client *des;
	struct i2c_atr *atr;
	unsigned int xlate_slots[BEIIS_NUM_LINKS];
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
static struct i2c_atr *beiis_atr;

static int beiis_xfer(struct i2c_adapter *adapter, struct i2c_msg *msgs, int num)
{
	int ret;

	ret = i2c_transfer(adapter, msgs, num);
	if (ret == num)
		return 0;

	return ret < 0 ? ret : -EIO;
}

static int beiis_write_reg(struct beiis_max96716a_atr *atr, u16 addr,
			   u16 reg, u8 value)
{
	u8 data[] = { reg >> 8, reg & 0xff, value };
	struct i2c_msg msg = {
		.addr = addr,
		.flags = 0,
		.len = sizeof(data),
		.buf = data,
	};

	return beiis_xfer(atr->des->adapter, &msg, 1);
}

static int beiis_read_reg(struct beiis_max96716a_atr *atr, u16 reg, u8 *value)
{
	u8 address[] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[] = {
		{
			.addr = atr->des->addr,
			.flags = 0,
			.len = sizeof(address),
			.buf = address,
		},
		{
			.addr = atr->des->addr,
			.flags = I2C_M_RD,
			.len = 1,
			.buf = value,
		},
	};

	return beiis_xfer(atr->des->adapter, msgs, ARRAY_SIZE(msgs));
}

/*
 * These sequences are the manually verified way to reach the still-default
 * serializer address 0x40 on this BE-IIS board. They are used only while
 * installing a translation in one serializer.
 */
static int beiis_select_link(struct beiis_max96716a_atr *atr, u32 chan)
{
	int ret;

	switch (chan) {
	case BEIIS_LINK_A:
		ret = beiis_write_reg(atr, atr->des->addr, 0x0f00, 0x01);
		if (ret)
			return ret;
		return beiis_write_reg(atr, atr->des->addr, 0x0010, 0x31);

	case BEIIS_LINK_B:
		ret = beiis_write_reg(atr, atr->des->addr, 0x0001, 0x02);
		if (ret)
			return ret;
		ret = beiis_write_reg(atr, atr->des->addr, 0x0011, 0x0b);
		if (ret)
			return ret;
		return beiis_write_reg(atr, atr->des->addr, 0x0010, 0x31);

	default:
		return -EINVAL;
	}
}

/*
 * The upstream MAX96716A driver keeps both remote control channels enabled.
 * Unique aliases make broadcasts harmless: only the serializer whose source
 * alias matches forwards the transaction to its local peripheral.
 */
static int beiis_enable_remote_control_channels(struct beiis_max96716a_atr *atr)
{
	u8 value;
	int ret;

	ret = beiis_read_reg(atr, MAX96716_REG1, &value);
	if (ret)
		return ret;
	ret = beiis_write_reg(atr, atr->des->addr, MAX96716_REG1,
			      value & ~MAX96716_REG1_DIS_REM_CC_A);
	if (ret)
		return ret;

	ret = beiis_read_reg(atr, MAX96716_REG3, &value);
	if (ret)
		return ret;
	return beiis_write_reg(atr, atr->des->addr, MAX96716_REG3,
			       value & ~MAX96716_REG3_DIS_REM_CC_B);
}

static int beiis_atr_attach_client(struct i2c_atr *i2c_atr, u32 chan,
				   const struct i2c_client *client, u16 alias)
{
	struct beiis_max96716a_atr *atr = i2c_atr_get_driver_data(i2c_atr);
	unsigned int slot;
	int ret;

	if (chan >= BEIIS_NUM_LINKS || client->addr > 0x7f)
		return -EINVAL;

	slot = atr->xlate_slots[chan];
	if (slot >= BEIIS_MAX_XLATES_PER_LINK) {
		dev_err(&atr->des->dev,
			"Link %u has no free MAX96717 translation slot for 0x%02x\n",
			chan, client->addr);
		return -ENOSPC;
	}

	/*
	 * The two serializers share their power-up address. Select the physical
	 * link before configuring its private translation slot.
	 */
	ret = beiis_select_link(atr, chan);
	if (ret)
		return ret;

	ret = beiis_write_reg(atr, serializer_addr, MAX96717_I2C_SRC(slot),
			      alias << 1);
	if (ret)
		return ret;

	ret = beiis_write_reg(atr, serializer_addr, MAX96717_I2C_DST(slot),
			      client->addr << 1);
	if (ret)
		return ret;

	atr->xlate_slots[chan]++;

	ret = beiis_enable_remote_control_channels(atr);
	if (ret)
		return ret;

	dev_info(&atr->des->dev,
		 "Link %c: remote 0x%02x is reachable as ATR alias 0x%02x\n",
		 chan == BEIIS_LINK_A ? 'A' : 'B', client->addr, alias);
	return 0;
}

static void beiis_atr_detach_client(struct i2c_atr *i2c_atr, u32 chan,
				    const struct i2c_client *client)
{
	/*
	 * Keep the MAX96717 mapping intact. The remote camera can remain powered
	 * while a Linux client is rebound, and the alias may be reused later.
	 */
}

static const struct i2c_atr_ops beiis_atr_ops = {
	.attach_client = beiis_atr_attach_client,
	.detach_client = beiis_atr_detach_client,
};

static int __init beiis_max96716a_atr_init(void)
{
	struct beiis_max96716a_atr *atr;
	struct i2c_board_info des_info = {
		I2C_BOARD_INFO("beiis-max96716a-atr", des_addr),
		.swnode = &beiis_atr_swnode,
	};
	int ret;

	beiis_parent = i2c_get_adapter(parent_bus);
	if (!beiis_parent)
		return -ENODEV;

	if (!i2c_check_functionality(beiis_parent, I2C_FUNC_I2C)) {
		ret = -EOPNOTSUPP;
		goto put_adapter;
	}

	/*
	 * The software node supplies i2c-alias-pool to Linux I2C-ATR. A plain
	 * i2c_new_dummy_device() has no fwnode and would make ATR refuse to load.
	 */
	beiis_des = i2c_new_client_device(beiis_parent, &des_info);
	if (IS_ERR(beiis_des)) {
		ret = PTR_ERR(beiis_des);
		beiis_des = NULL;
		goto put_adapter;
	}

	atr = devm_kzalloc(&beiis_des->dev, sizeof(*atr), GFP_KERNEL);
	if (!atr) {
		ret = -ENOMEM;
		goto unregister_des;
	}

	atr->des = beiis_des;
	beiis_atr = i2c_atr_new(beiis_parent, &beiis_des->dev,
				&beiis_atr_ops, BEIIS_NUM_LINKS);
	if (IS_ERR(beiis_atr)) {
		ret = PTR_ERR(beiis_atr);
		beiis_atr = NULL;
		goto unregister_des;
	}

	i2c_atr_set_driver_data(beiis_atr, atr);

	ret = i2c_atr_add_adapter(beiis_atr, BEIIS_LINK_A, NULL, NULL);
	if (ret)
		goto delete_atr;

	ret = i2c_atr_add_adapter(beiis_atr, BEIIS_LINK_B, NULL, NULL);
	if (ret)
		goto del_link_a;

	dev_info(&beiis_des->dev,
		 "BE-IIS I2C-ATR ready: add downstream clients at native addresses\n");
	return 0;

del_link_a:
	i2c_atr_del_adapter(beiis_atr, BEIIS_LINK_A);
delete_atr:
	i2c_atr_delete(beiis_atr);
	beiis_atr = NULL;
unregister_des:
	i2c_unregister_device(beiis_des);
	beiis_des = NULL;
put_adapter:
	i2c_put_adapter(beiis_parent);
	beiis_parent = NULL;
	return ret;
}

static void __exit beiis_max96716a_atr_exit(void)
{
	i2c_atr_del_adapter(beiis_atr, BEIIS_LINK_B);
	i2c_atr_del_adapter(beiis_atr, BEIIS_LINK_A);
	i2c_atr_delete(beiis_atr);
	i2c_unregister_device(beiis_des);
	i2c_put_adapter(beiis_parent);
}

module_init(beiis_max96716a_atr_init);
module_exit(beiis_max96716a_atr_exit);

MODULE_DESCRIPTION("BE-IIS MAX96716A dual-link I2C Address Translator");
MODULE_AUTHOR("BE-IIS");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("I2C_ATR");
