/* SPDX-License-Identifier: GPL-2.0 */
/*
 *  linux/boot/head.S
 *
 *  Copyright (C) 1991, 1992, 1993  Linus Torvalds
 */

/*
 *  head.S contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00001000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory. [According to comments etc elsewhere on a compressed
 * kernel it will end up at 0x1000 + 1Mb I hope so as I assume this. - AC]
 *
 * Page 0 is deliberately kept safe, since System Management Mode code in 
 * laptops may need to access the BIOS data stored there.  This is also
 * useful for future device drivers that either access the BIOS via VM86 
 * mode.
 */

/*
 * High loaded stuff by Hans Lermen & Werner Almesberger, Feb. 1996
 */
	.code32
	.text

#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/boot.h>
#include <asm/msr.h>
#include <asm/processor-flags.h>
#include <asm/asm-offsets.h>
#include <asm/bootparam.h>
#include "pgtable.h"

/*
 * Locally defined symbols should be marked hidden:
 */
	.hidden _bss
	.hidden _ebss
	.hidden _got
	.hidden _egot

	/*进入保护模式后会跳转到如下位置执行，该标号的地址在链接脚步中设置为0*/
	/*#define __HEAD .section ".head.text","ax"*/
	__HEAD
	.code32
ENTRY(startup_32)
	/*
	 * 32bit entry is 0 and it is ABI so immutable!
	 * If we come here directly from a bootloader,
	 * kernel(text+data+bss+brk) ramdisk, zero_page, command line
	 * all need to be under the 4G limit.
	 */
	/*
	cld指令将标志寄存器的DF(方向标志)位清空.当方向标志被清空,所有的串操作指令
	像stos,scas等等将会增加索引寄存器esi或者edi的值.我们需要清空方向标志是因为
	接下来我们会使用汇编的串操作指令来做为页表腾出空间等工作
	*/
	cld
	/*
	 * Test KEEP_SEGMENTS flag to see if the bootloader is asking
	 * us to not reload segments
	 */
	/*从内核加载头中的loadflags字段来检查KEEP_SEGMENTS标志*/
	testb $KEEP_SEGMENTS, BP_loadflags(%esi)

	/*如果设置了KEEP_SEGMENTS标志，则跳转到1标号执行*/
	jnz 1f

	/*如果没有设置，则重新使用__BOOT_DS设置各个段寄存器*/
	cli
	movl	$(__BOOT_DS), %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
1:

/*
 * Calculate the delta between where we were compiled to run
 * at and where we were actually loaded at.  This can only be done
 * with a short local call on x86.  Nothing  else will tell us what
 * address we are running at.  The reserved chunk of the real-mode
 * data at 0x1e4 (defined as a scratch field) are used as the stack
 * for this calculation. Only 4 bytes are needed.
 */
	/*为下面的call指令设置一个4字节的临时堆栈*/
	leal	(BP_scratch+4)(%esi), %esp

	/*获取startup_32函数的起始地址，并把该地址放入ebp寄存器中*/
	call	1f
1:	popl	%ebp
	subl	$1b, %ebp

/* setup a stack and make sure cpu supports long mode. */
	/*计算真正的堆栈地址$boot_stack_end+ebp,并把该地址写入栈顶指针*/
	movl	$boot_stack_end, %eax
	addl	%ebp, %eax
	movl	%eax, %esp

	/*检查CPU对长模式和SSE的支持，通过eax寄存器返回0表示成功，1表示失败*/
	call	verify_cpu

	/*如果eax的值不是0，我们就跳转到no_longmode标签，用hlt指令停止CPU*/
	testl	%eax, %eax
	jnz	no_longmode

/*
 * Compute the delta between where we were compiled to run at
 * and where the code will actually run at.
 *
 * %ebp contains the address we are loaded at by the boot loader and %ebx
 * contains the address where we should move the kernel image temporarily
 * for safe in-place decompression.
 */

/*如果CONFIG_RELOCATABLE=y，那么内核将会从其被加载的位置运行，编译时的物理地址
(CONFIG_PHYSICAL_START)将会被作为最低地址位置的限制,该地址定义为16M*/
#ifdef CONFIG_RELOCATABLE
	/*如果配置了可重定位内核,则首先进行对齐处理,其中esi为boot parameter的地址,ebp为当前运行地址*/
	movl	%ebp, %ebx
	movl	BP_kernel_alignment(%esi), %eax
	decl	%eax
	addl	%eax, %ebx
	notl	%eax
	andl	%eax, %ebx

	/*比较对齐后的地址和预设的加载地址*/
	cmpl	$LOAD_PHYSICAL_ADDR, %ebx

	/*如果大于预设的加载地址，则顺利通过*/
	jge	1f
#endif
	/*如果小于预设的加载地址，则使用预设的加载地址*/
	movl	$LOAD_PHYSICAL_ADDR, %ebx
1:

	/*ebx被设为内核解压缩的目标地址,紧接着该地址放临时页表*/
	/* Target address to relocate to for decompression */
	movl	BP_init_size(%esi), %eax
	subl	$_end, %eax
	addl	%eax, %ebx

/*
 * Prepare for entering 64 bit mode
 */

	/*将32位描述符中的字段改为CS.L = 1 CS.D = 0从而在64位模
	  式下执行把修正后的gdt地址加载进gtdr寄存器*/
	/* Load new GDT with the 64bit segments using 32bit descriptor */
	addl	%ebp, gdt+2(%ebp)
	lgdt	gdt(%ebp)

	/*使能PAE模式,为进入64位模式做准备*/
	/* Enable PAE mode */
	movl	%cr4, %eax
	orl	$X86_CR4_PAE, %eax
	movl	%eax, %cr4

	/*下面是建立4G空间的启动页表,供64位模式使用
	Linux内核使用4级页表，通常我们会建立6个页表：
	1个PML4或称为4级页映射表，包含1个项；
	1个PDP或称为页目录指针表，包含4个项；
	4个页目录表，一共包含2048个项；
	*/
 /*
  * Build early 4G boot pagetable
  */
	/*
	 * If SEV is active then set the encryption mask in the page tables.
	 * This will insure that when the kernel is copied and decompressed
	 * it will be done so encrypted.
	 */
	call	get_sev_encryption_bit
	xorl	%edx, %edx
	testl	%eax, %eax
	jz	1f
	subl	$32, %eax	/* Encryption bit is always above bit 31 */
	bts	%eax, %edx	/* Set encryption mask for page tables */
1:
	/*在内存中为页表清理一块缓存,大小为#define BOOT_INIT_PGT_SIZE	(6*4096)*/
	/* Initialize Page tables to 0 */
	leal	pgtable(%ebx), %edi
	xorl	%eax, %eax
	movl	$(BOOT_INIT_PGT_SIZE/4), %ecx
	rep	stosl

	/*构建顶级页表-PML4*/
	/* Build Level 4 */
	leal	pgtable + 0(%ebx), %edi
	leal	0x1007 (%edi), %eax
	movl	%eax, 0(%edi)
	addl	%edx, 4(%edi)

	/*在页目录指针(PDP)表(3级页表)建立4个带有PRESENT+RW+USE标记的Page Directory(2级页表)项*/
	/* Build Level 3 */
	leal	pgtable + 0x1000(%ebx), %edi
	leal	0x1007(%edi), %eax
	movl	$4, %ecx
1:	movl	%eax, 0x00(%edi)
	addl	%edx, 0x04(%edi)
	addl	$0x00001000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

	/*建立2048个2MB页的页表项*/
	/* Build Level 2 */
	leal	pgtable + 0x2000(%ebx), %edi
	movl	$0x00000183, %eax
	movl	$2048, %ecx
1:	movl	%eax, 0(%edi)
	addl	%edx, 4(%edi)
	addl	$0x00200000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

	/*建立完成后，把页表的物理地址放入cr3寄存器*/
	/* Enable the boot page tables */
	leal	pgtable(%ebx), %eax
	movl	%eax, %cr3

	/*设置MSR中的EFER.LME标记为0xC0000080*/
	/* Enable Long mode in EFER (Extended Feature Enable Register) */
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_LME, %eax
	wrmsr

	/*重新加载ldt和tr寄存器*/
	/* After gdt is loaded */
	xorl	%eax, %eax
	lldt	%ax
	movl    $__BOOT_TSS, %eax
	ltr	%ax

	/*
	 * Setup for the jump to 64bit mode
	 *
	 * When the jump is performend we will be in long mode but
	 * in 32bit compatibility mode with EFER.LME = 1, CS.L = 0, CS.D = 1
	 * (and in turn EFER.LMA = 1).	To jump into 64bit mode we use
	 * the new gdt/idt that has __KERNEL_CS with CS.L = 1.
	 * We place all of the values on our mini stack so lret can
	 * used to perform that far jump.
	 */
	/*把cs和ip压入堆栈，以便lret返回时，直接指向压入的地址*/
	pushl	$__KERNEL_CS
	leal	startup_64(%ebp), %eax
#ifdef CONFIG_EFI_MIXED
	movl	efi32_config(%ebp), %ebx
	cmp	$0, %ebx
	jz	1f
	leal	handover_entry(%ebp), %eax
1:
#endif
	pushl	%eax

	/*设置cr0，使能保护模式和分页模式*/
	/* Enter paged protected Mode, activating Long Mode */
	movl	$(X86_CR0_PG | X86_CR0_PE), %eax /* Enable Paging and Protected mode */
	movl	%eax, %cr0

	/*执行该指令，弹出前面压入堆栈的值到cs和ip，开始执行startup_64标号地址*/
	/* Jump from 32bit compatibility mode into 64bit mode. */
	lret
ENDPROC(startup_32)

#ifdef CONFIG_EFI_MIXED
	.org 0x190
ENTRY(efi32_stub_entry)
	add	$0x4, %esp		/* Discard return address */
	popl	%ecx
	popl	%edx
	popl	%esi

	leal	(BP_scratch+4)(%esi), %esp
	call	1f
1:	pop	%ebp
	subl	$1b, %ebp

	movl	%ecx, efi32_config(%ebp)
	movl	%edx, efi32_config+8(%ebp)
	sgdtl	efi32_boot_gdt(%ebp)

	leal	efi32_config(%ebp), %eax
	movl	%eax, efi_config(%ebp)

	jmp	startup_32
ENDPROC(efi32_stub_entry)
#endif

/*64位模式执行的第一条指令*/
	.code64
	.org 0x200
ENTRY(startup_64)
	/*
	 * 64bit entry is 0x200 and it is ABI so immutable!
	 * We come here either from startup_32 or directly from a
	 * 64bit bootloader.
	 * If we come here from a bootloader, kernel(text+data+bss+brk),
	 * ramdisk, zero_page, command line could be above 4G.
	 * We depend on an identity mapped page table being provided
	 * that maps our entire kernel(text+data+bss+brk), zero page
	 * and command line.
	 */

	/*把段寄存器清零*/
	/* Setup data segments. */
	xorl	%eax, %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
	movl	%eax, %fs
	movl	%eax, %gs

	/*
	 * Compute the decompressed kernel start address.  It is where
	 * we were loaded at aligned to a 2M boundary. %rbp contains the
	 * decompressed kernel start address.
	 *
	 * If it is a relocatable kernel then decompress and run the kernel
	 * from load address aligned to 2MB addr, otherwise decompress and
	 * run the kernel from LOAD_PHYSICAL_ADDR
	 *
	 * We cannot rely on the calculation done in 32-bit mode, since we
	 * may have been invoked via the 64-bit entry point.
	 */

	/*计算内核编译时的位置和它被加载的位置的差*/
	/* Start with the delta to where the kernel will run at. */
#ifdef CONFIG_RELOCATABLE
	/*处理rbp对齐后的地址*/
	leaq	startup_32(%rip) /* - $startup_32 */, %rbp
	movl	BP_kernel_alignment(%rsi), %eax
	decl	%eax
	addq	%rax, %rbp
	notq	%rax
	andq	%rax, %rbp

	/*比较对齐后的地址与预设的地址*/
	cmpq	$LOAD_PHYSICAL_ADDR, %rbp

	/*如果对齐后的地址大于预设的地址，则okay*/
	jge	1f
#endif
	/*如果小于预设的地址，则直接设置为预设的地址，也就是解压缩的源地址*/
	movq	$LOAD_PHYSICAL_ADDR, %rbp
1:

	/*下面代码执行后rbx会包含用于解压缩的目的地址*/
	/* Target address to relocate to for decompression */
	movl	BP_init_size(%rsi), %ebx
	subl	$_end, %ebx
	addq	%rbp, %rbx

	/*rbx寄存器包含了内核解压后代码的起始地址，我们把这个地址的boot_stack_end
	  偏移地址相加放到表示栈顶指针的rsp寄存器*/
	/* Set up the stack */
	leaq	boot_stack_end(%rbx), %rsp

	/*
	 * paging_prepare() and cleanup_trampoline() below can have GOT
	 * references. Adjust the table with address we are running at.
	 *
	 * Zero RAX for adjust_got: the GOT was not adjusted before;
	 * there's no adjustment to undo.
	 */
	/*清零rax寄存器*/
	xorq	%rax, %rax

	/*
	 * Calculate the address the binary is loaded at and use it as
	 * a GOT adjustment.
	 */
	/*计算该文件的起始地址并放入rdi中，用于got表调整*/
	call	1f
1:	popq	%rdi
	subq	$1b, %rdi

	/*调用该函数，调整got表*/
	call	adjust_got

	/*
	 * At this point we are in long mode with 4-level paging enabled,
	 * but we might want to enable 5-level paging or vice versa.
	 *
	 * The problem is that we cannot do it directly. Setting or clearing
	 * CR4.LA57 in long mode would trigger #GP. So we need to switch off
	 * long mode and paging first.
	 *
	 * We also need a trampoline in lower memory to switch over from
	 * 4- to 5-level paging for cases when the bootloader puts the kernel
	 * above 4G, but didn't enable 5-level paging for us.
	 *
	 * The same trampoline can be used to switch from 5- to 4-level paging
	 * mode, like when starting 4-level paging kernel via kexec() when
	 * original kernel worked in 5-level paging mode.
	 *
	 * For the trampoline, we need the top page table to reside in lower
	 * memory as we don't have a way to load 64-bit values into CR3 in
	 * 32-bit mode.
	 *
	 * We go though the trampoline even if we don't have to: if we're
	 * already in a desired paging mode. This way the trampoline code gets
	 * tested on every boot.
	 */

	/*使用32位的全局描述符设置gdt64标号描述符，并加载到gdtr寄存器*/
	/* Make sure we have GDT with 32-bit code segment */
	leaq	gdt(%rip), %rax
	movq	%rax, gdt64+2(%rip)
	lgdt	gdt64(%rip)

	/*
	 * paging_prepare() sets up the trampoline and checks if we need to
	 * enable 5-level paging.
	 *
	 * Address of the trampoline is returned in RAX.
	 * Non zero RDX on return means we need to enable 5-level paging.
	 *
	 * RSI holds real mode data and needs to be preserved across
	 * this function call.
	 */
	pushq	%rsi
	movq	%rsi, %rdi		/* real mode address */
	call	paging_prepare
	popq	%rsi

	/* Save the trampoline address in RCX */
	movq	%rax, %rcx

	/*
	 * Load the address of trampoline_return() into RDI.
	 * It will be used by the trampoline to return to the main code.
	 */
	leaq	trampoline_return(%rip), %rdi

	/* Switch to compatibility mode (CS.L = 0 CS.D = 1) via far return */
	pushq	$__KERNEL32_CS
	leaq	TRAMPOLINE_32BIT_CODE_OFFSET(%rax), %rax
	pushq	%rax
	lretq
trampoline_return:
	/* Restore the stack, the 32-bit trampoline uses its own stack */
	leaq	boot_stack_end(%rbx), %rsp

	/*
	 * cleanup_trampoline() would restore trampoline memory.
	 *
	 * RDI is address of the page table to use instead of page table
	 * in trampoline memory (if required).
	 *
	 * RSI holds real mode data and needs to be preserved across
	 * this function call.
	 */
	pushq	%rsi
	leaq	top_pgtable(%rbx), %rdi
	call	cleanup_trampoline
	popq	%rsi

	/*清除eflags寄存器*/
	/* Zero EFLAGS */
	pushq	$0
	popfq

	/*
	 * Previously we've adjusted the GOT with address the binary was
	 * loaded at. Now we need to re-adjust for relocation address.
	 *
	 * Calculate the address the binary is loaded at, so that we can
	 * undo the previous GOT adjustment.
	 */
	/*重新调整got表*/
	call	1f
1:	popq	%rax
	subq	$1b, %rax

	/* The new adjustment is the relocation address */
	movq	%rbx, %rdi
	call	adjust_got

/*
 * Copy the compressed kernel to the end of our buffer
 * where decompression in place becomes safe.
 */
	/*rsi中包含boot_params指针，所以先保存起来*/
	pushq	%rsi

	/*rsi包含_bss-8的绝对地址,也就是移动前压缩镜像的末尾*/
	leaq	(_bss-8)(%rip), %rsi

	/*rdi包含_bss-8的相对地址,也就是移动后压缩镜像的末尾*/
	leaq	(_bss-8)(%rbx), %rdi

	/*把要拷贝的大小放入rcx中*/
	movq	$_bss /* - $startup_32 */, %rcx

	/*每次拷贝8个字节*/
	shrq	$3, %rcx

	/*设置方向标记，意味着从后往前复制这些字节*/
	std

	/*循环拷贝*/
	rep	movsq

	/*重新清除标记*/
	cld

	/*把保存在栈中的boot_params重新弹出到rsi寄存器*/
	popq	%rsi

/*
 * Jump to the relocated address.
 */
	/*把相对于rbx的地址偏移relocated(rbx+relocated)放入rax中*/
	leaq	relocated(%rbx), %rax

	/*跳转到标签relocated处执行*/
	jmp	*%rax

#ifdef CONFIG_EFI_STUB

/* The entry point for the PE/COFF executable is efi_pe_entry. */
ENTRY(efi_pe_entry)
	movq	%rcx, efi64_config(%rip)	/* Handle */
	movq	%rdx, efi64_config+8(%rip) /* EFI System table pointer */

	leaq	efi64_config(%rip), %rax
	movq	%rax, efi_config(%rip)

	call	1f
1:	popq	%rbp
	subq	$1b, %rbp

	/*
	 * Relocate efi_config->call().
	 */
	addq	%rbp, efi64_config+40(%rip)

	movq	%rax, %rdi
	call	make_boot_params
	cmpq	$0,%rax
	je	fail
	mov	%rax, %rsi
	leaq	startup_32(%rip), %rax
	movl	%eax, BP_code32_start(%rsi)
	jmp	2f		/* Skip the relocation */

handover_entry:
	call	1f
1:	popq	%rbp
	subq	$1b, %rbp

	/*
	 * Relocate efi_config->call().
	 */
	movq	efi_config(%rip), %rax
	addq	%rbp, 40(%rax)
2:
	movq	efi_config(%rip), %rdi
	call	efi_main
	movq	%rax,%rsi
	cmpq	$0,%rax
	jne	2f
fail:
	/* EFI init failed, so hang. */
	hlt
	jmp	fail
2:
	movl	BP_code32_start(%esi), %eax
	leaq	startup_64(%rax), %rax
	jmp	*%rax
ENDPROC(efi_pe_entry)

	.org 0x390
ENTRY(efi64_stub_entry)
	movq	%rdi, efi64_config(%rip)	/* Handle */
	movq	%rsi, efi64_config+8(%rip) /* EFI System table pointer */

	leaq	efi64_config(%rip), %rax
	movq	%rax, efi_config(%rip)

	movq	%rdx, %rsi
	jmp	handover_entry
ENDPROC(efi64_stub_entry)
#endif

	.text
relocated:

/*
 * Clear BSS (stack is currently empty)
 */
	/*清除bss段*/
	xorl	%eax, %eax
	leaq    _bss(%rip), %rdi
	leaq    _ebss(%rip), %rcx
	subq	%rdi, %rcx
	shrq	$3, %rcx
	rep	stosq

/*
 * Do the extraction, and jump to the new kernel..
 */
	/*解压缩内核，然后跳到解压处执行,返回地址放在rax处*/
	pushq	%rsi			/* Save the real mode argument */

	/*为extract_kernel函数准备参数,rdi,%rsi,%rdx,%rcx,%r8,%r9用
	  作函数参数,依次对应第1参数,第2参数,......*/
	movq	%rsi, %rdi		/* real mode address */
	leaq	boot_heap(%rip), %rsi	/* malloc area for uncompression */
	leaq	input_data(%rip), %rdx  /* input_data */
	movl	$z_input_len, %ecx	/* input_len */
	movq	%rbp, %r8		/* output target address */
	movq	$z_output_len, %r9	/* decompressed length, end of relocs */

	/*调用该函数解压内核,解压后内核的地址保存在rax中*/
	call	extract_kernel		/* returns kernel location in %rax */
	popq	%rsi

/*
 * Jump to the decompressed kernel.
 */
	/*跳到内核解压后的地址startup_64执行,解压缩后的内核镜像的入口
	点startup_64定义在arch/x86/kernel/head_64.S*/
	jmp	*%rax

/*
 * Adjust the global offset table
 *
 * RAX is the previous adjustment of the table to undo (use 0 if it's the
 * first time we touch GOT).
 * RDI is the new adjustment to apply.
 */
adjust_got:
	/* Walk through the GOT adding the address to the entries */
	leaq	_got(%rip), %rdx
	leaq	_egot(%rip), %rcx
1:
	cmpq	%rcx, %rdx
	jae	2f
	subq	%rax, (%rdx)	/* Undo previous adjustment */
	addq	%rdi, (%rdx)	/* Apply the new adjustment */
	addq	$8, %rdx
	jmp	1b
2:
	ret

	.code32
/*
 * This is the 32-bit trampoline that will be copied over to low memory.
 *
 * RDI contains the return address (might be above 4G).
 * ECX contains the base address of the trampoline memory.
 * Non zero RDX on return means we need to enable 5-level paging.
 */
ENTRY(trampoline_32bit_src)
	/* Set up data and stack segments */
	movl	$__KERNEL_DS, %eax
	movl	%eax, %ds
	movl	%eax, %ss

	/* Set up new stack */
	leal	TRAMPOLINE_32BIT_STACK_END(%ecx), %esp

	/* Disable paging */
	movl	%cr0, %eax
	btrl	$X86_CR0_PG_BIT, %eax
	movl	%eax, %cr0

	/* Check what paging mode we want to be in after the trampoline */
	cmpl	$0, %edx
	jz	1f

	/* We want 5-level paging: don't touch CR3 if it already points to 5-level page tables */
	movl	%cr4, %eax
	testl	$X86_CR4_LA57, %eax
	jnz	3f
	jmp	2f
1:
	/* We want 4-level paging: don't touch CR3 if it already points to 4-level page tables */
	movl	%cr4, %eax
	testl	$X86_CR4_LA57, %eax
	jz	3f
2:
	/* Point CR3 to the trampoline's new top level page table */
	leal	TRAMPOLINE_32BIT_PGTABLE_OFFSET(%ecx), %eax
	movl	%eax, %cr3
3:
	/* Enable PAE and LA57 (if required) paging modes */
	movl	$X86_CR4_PAE, %eax
	cmpl	$0, %edx
	jz	1f
	orl	$X86_CR4_LA57, %eax
1:
	movl	%eax, %cr4

	/* Calculate address of paging_enabled() once we are executing in the trampoline */
	leal	paging_enabled - trampoline_32bit_src + TRAMPOLINE_32BIT_CODE_OFFSET(%ecx), %eax

	/* Prepare the stack for far return to Long Mode */
	pushl	$__KERNEL_CS
	pushl	%eax

	/* Enable paging again */
	movl	$(X86_CR0_PG | X86_CR0_PE), %eax
	movl	%eax, %cr0

	lret

	.code64
paging_enabled:
	/* Return from the trampoline */
	jmp	*%rdi

	/*
         * The trampoline code has a size limit.
         * Make sure we fail to compile if the trampoline code grows
         * beyond TRAMPOLINE_32BIT_CODE_SIZE bytes.
	 */
	.org	trampoline_32bit_src + TRAMPOLINE_32BIT_CODE_SIZE

	.code32
no_longmode:
	/* This isn't an x86-64 CPU, so hang intentionally, we cannot continue */
1:
	hlt
	jmp     1b

#include "../../kernel/verify_cpu.S"

	.data
gdt64:
	.word	gdt_end - gdt
	.long	0
	.word	0
	.quad   0
gdt:
	.word	gdt_end - gdt
	.long	gdt
	.word	0
	.quad	0x00cf9a000000ffff	/* __KERNEL32_CS */
	.quad	0x00af9a000000ffff	/* __KERNEL_CS */
	.quad	0x00cf92000000ffff	/* __KERNEL_DS */
	.quad	0x0080890000000000	/* TS descriptor */
	.quad   0x0000000000000000	/* TS continued */
gdt_end:

#ifdef CONFIG_EFI_STUB
efi_config:
	.quad	0

#ifdef CONFIG_EFI_MIXED
	.global efi32_config
efi32_config:
	.fill	5,8,0
	.quad	efi64_thunk
	.byte	0
#endif

	.global efi64_config
efi64_config:
	.fill	5,8,0
	.quad	efi_call
	.byte	1
#endif /* CONFIG_EFI_STUB */

/*
 * Stack and heap for uncompression
 */
	.bss
	.balign 4
boot_heap:
	.fill BOOT_HEAP_SIZE, 1, 0
boot_stack:
	.fill BOOT_STACK_SIZE, 1, 0
boot_stack_end:

/*
 * Space for page tables (not in .bss so not zeroed)
 */
	.section ".pgtable","a",@nobits
	.balign 4096
pgtable:
	.fill BOOT_PGT_SIZE, 1, 0

/*
 * The page table is going to be used instead of page table in the trampoline
 * memory.
 */
top_pgtable:
	.fill PAGE_SIZE, 1, 0
