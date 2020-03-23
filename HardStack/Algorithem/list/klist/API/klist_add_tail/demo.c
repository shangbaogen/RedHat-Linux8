/*
 * klist: klist_add_tail
 *
 * void klist_add_tail(struct klist_node *n, struct klist *k)
 *
 * struct klist_node {
 *     void             *n_klist;
 *     struct list_head n_node;
 *     struct kref      n_ref;
 * };
 *
 * struct klist {
 *     spinlock_t       k_lock;
 *     struct list_head k_list;
 *     void             (*get)(struct klist_node *);
 *     void             (*put)(struct klist_node *);
 * } __attribute__((aligned(sizeof(void *))));
 *
 * (C) 20179.01.25 <buddy.zhang@aliyun.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

/*
 * Embedded bidirect-list between klist and klist_node.
 *
 * +----------+          +------------+          +------------+
 * |          |          |            |          |            |
 * |  klist   |          | klist_node |          | klist_node |
 * |   k_list |<-------->|     n_node |<-------->|     n_node |
 * |          |          |            |          |            |
 * +----------+          +------------+          +------------+
 *
 */

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>

/* header of klist */
#include <linux/klist.h>

/* klist struct */
static struct klist *klist;

struct node {
    const char *name;
    struct klist_node n;
};

static struct node node0 = { .name = "BiscuitOs_node0", };
static struct node node1 = { .name = "BiscuitOs_node1", };
static struct node node2 = { .name = "BiscuitOs_node2", };
static struct node node3 = { .name = "BiscuitOs_node3", };
static struct node node4 = { .name = "BiscuitOs_node4", };
static struct node node5 = { .name = "BiscuitOs_node5", };
static struct node node6 = { .name = "BiscuitOs_node6", };
static struct node node7 = { .name = "BiscuitOs_node7", };
static struct node node8 = { .name = "BiscuitOs_node8", };

/* klist get */
static void demo_klist_get(struct klist_node *n)
{
    printk("Demo klist get.\n");
}

/* klist put */
static void demo_klist_put(struct klist_node *n)
{
    printk("Demo klist put.\n");
}

static __init int klist_demo_init(void)
{
    struct klist_node *np;
    struct node *nodep;

    printk("Klist Procedure entence...\n");

    /* allocate memory*/
    klist = (struct klist *)kmalloc(sizeof(*klist), GFP_KERNEL);
    if (!klist)
        return -ENOMEM;

    /* Initialize klist  */
    klist_init(klist, demo_klist_get, demo_klist_put);

    /* Initialize a klist_node and add it to back */
    klist_add_tail(&node0.n, klist);

    /* Initialize a klist_node and add it to head */
    klist_add_head(&node1.n, klist);
    klist_add_head(&node2.n, klist);
    klist_add_head(&node3.n, klist);
    klist_add_head(&node4.n, klist);
    klist_add_head(&node5.n, klist);
    klist_add_head(&node6.n, klist);
    klist_add_head(&node7.n, klist);
    klist_add_head(&node8.n, klist);

    /* Traverse all klist_node */
    printk("Traverse klist:\n");
    list_for_each_entry(np, &klist->k_list, n_node) {
        nodep = list_entry(np, struct node, n);
        if (nodep)
            printk("%s\n", nodep->name);
    }

    /* Decreament the refcount of node and wait for it to go away */
    klist_remove(&node0.n);
    klist_remove(&node1.n);
    klist_remove(&node2.n);
    klist_remove(&node3.n);
    klist_remove(&node4.n);
    klist_remove(&node5.n);
    klist_remove(&node6.n);
    klist_remove(&node7.n);
    klist_remove(&node8.n);

    return 0;
}
device_initcall(klist_demo_init);
