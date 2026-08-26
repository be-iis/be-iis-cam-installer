// SPDX-License-Identifier: GPL-2.0-only
/*
 * BE-IIS MAX96716A primary-control-channel I2C mux.
 *
 * This module exposes two virtual I2C adapters for the two GMSL links.
 * Before a transaction on either child adapter it selects that physical link
 * using the verified MAX96716A register sequence.
 *
 * It is intentionally not a media/GMSL/CSI driver. It only multiplexes I2C.
 * Attach ordinary sensor devices to the child adapters at their native
 * remote address (IMX708: 0x1a).
 */
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/i2c-mux.h>
#include <linux/init.h>
#include <linux/module.h>

#define BEIIS_LINK_A 0
#define BEIIS_LINK_B 1

struct beiis_max96716a_mux {
	struct i2c_client *des;
};

static int parent_bus = 11;
module_param(parent_bus, int, 0444);
MODULE_PARM_DESC(parent_bus, "Parent I2C adapter number (default: 11)");

static ushort des_addr = 0x28;
module_param(des_addr, ushort, 0444);
MODULE_PARM_DESC(des_addr, "MAX96716A 7-bit I2C address (default: 0x28)");

static int link_a_bus = 30;
module_param(link_a_bus, int, 0444);
MODULE_PARM_DESC(link_a_bus, "Virtual I2C adapter number for Link A (default: 30)");

static int link_b_bus = 31;
module_param(link_b_bus, int, 0444);
MODULE_PARM_DESC(link_b_bus, "Virtual I2C adapter number for Link B (default: 31)");

static struct i2c_adapter *beiis_parent;
static struct i2c_client *beiis_des;
static struct i2c_mux_core *beiis_muxc;

static int beiis_write_reg(struct beiis_max96716a_mux *mux, u16 reg, u8 value)
{
	u8 data[] = { reg >> 8, reg & 0xff, value };
	struct i2c_msg msg = {
		.addr = mux->des->addr,
		.flags = 0,
		.len = sizeof(data),
		.buf = data,
	};
	int ret;

	ret = i2c_transfer(mux->des->adapter, &msg, 1);
	if (ret == 1)
		return 0;

	return ret < 0 ? ret : -EIO;
}

static int beiis_select(struct i2c_mux_core *muxc, u32 chan)
{
	struct beiis_max96716a_mux *mux = i2c_mux_priv(muxc);
	int ret;

	switch (chan) {
	case BEIIS_LINK_A:
		/* Verified manual Link-A selection. */
		ret = beiis_write_reg(mux, 0x0f00, 0x01);
		if (ret)
			return ret;
		return beiis_write_reg(mux, 0x0010, 0x31);

	case BEIIS_LINK_B:
		/* Verified manual Link-B selection. */
		ret = beiis_write_reg(mux, 0x0001, 0x02);
		if (ret)
			return ret;
		ret = beiis_write_reg(mux, 0x0011, 0x0b);
		if (ret)
			return ret;
		return beiis_write_reg(mux, 0x0010, 0x31);

	default:
		return -EINVAL;
	}
}

static int __init beiis_max96716a_mux_init(void)
{
	struct beiis_max96716a_mux *mux;
	int ret;

	beiis_parent = i2c_get_adapter(parent_bus);
	if (!beiis_parent)
		return -ENODEV;

	beiis_des = i2c_new_dummy_device(beiis_parent, des_addr);
	if (IS_ERR(beiis_des)) {
		ret = PTR_ERR(beiis_des);
		beiis_des = NULL;
		goto put_adapter;
	}

	beiis_muxc = i2c_mux_alloc(beiis_parent, &beiis_des->dev, 2,
				   sizeof(*mux), 0, beiis_select, NULL);
	if (!beiis_muxc) {
		ret = -ENOMEM;
		goto unregister_des;
	}

	mux = i2c_mux_priv(beiis_muxc);
	mux->des = beiis_des;

	ret = i2c_mux_add_adapter(beiis_muxc, link_a_bus, BEIIS_LINK_A);
	if (ret)
		goto unregister_des;

	ret = i2c_mux_add_adapter(beiis_muxc, link_b_bus, BEIIS_LINK_B);
	if (ret)
		goto del_adapters;

	pr_info("beiis-max96716a-i2c-mux: i2c-%d Link A, i2c-%d Link B (parent i2c-%d)\\n",
		beiis_muxc->adapter[0]->nr, beiis_muxc->adapter[1]->nr,
		parent_bus);
	return 0;

del_adapters:
	i2c_mux_del_adapters(beiis_muxc);
unregister_des:
	i2c_unregister_device(beiis_des);
	beiis_des = NULL;
put_adapter:
	i2c_put_adapter(beiis_parent);
	beiis_parent = NULL;
	return ret;
}

static void __exit beiis_max96716a_mux_exit(void)
{
	i2c_mux_del_adapters(beiis_muxc);
	i2c_unregister_device(beiis_des);
	i2c_put_adapter(beiis_parent);
}

module_init(beiis_max96716a_mux_init);
module_exit(beiis_max96716a_mux_exit);

MODULE_DESCRIPTION("BE-IIS MAX96716A primary I2C control-channel mux");
MODULE_AUTHOR("BE-IIS");
MODULE_LICENSE("GPL");
