/*
 * Bitmap.
 *
 * (C) 2019.06.10 <buddy.zhang@aliyun.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/kernel.h>
#include <linux/init.h>

/* header of bitmap */
#include <linux/bitmap.h>

/* Declare bitmap */
DECLARE_BITMAP(bitmap, 32);

static __init int bitmap_demo_init(void)
{
	unsigned long pos;

	bitmap_set(bitmap, 4, 8);

	for_each_set_bit(pos, bitmap, 24)
		printk("POS: %ld\n", pos);

	return 0;
}
device_initcall(bitmap_demo_init);
