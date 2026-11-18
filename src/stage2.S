.code16
.section .text
.global stage2_start


# ============================================================
# Konfigurácia obrazu
# ============================================================

.set KERNEL_LBA,          399736
.set INITRAMFS_LBA,       719928

.set KERNEL_ADDRESS,      0x00100000
.set INITRAMFS_ADDRESS,   0x08000000
.set INITRAMFS_SIZE,      38746088

.set COMMAND_LINE_ADDRESS, 0x00020000

.set BOUNCE_SEGMENT,      0x5000
.set MAX_READ_SECTORS,    64


# ============================================================
# Začiatok stage 2
# ============================================================

stage2_start:
    cli

    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp

    sti

    movb %dl, boot_drive

    call serial_init

    movw $welcome_message, %si
    call print_string

    call get_e820_memory_map
    jc e820_error

    movw $e820_message, %si
    call print_string

    movw memory_entry_count, %ax
    call print_hex16

    movw $newline, %si
    call print_string

    # Načítanie prvých dvoch sektorov kernelu.
    movw $2, dap_sector_count
    movw $0, dap_buffer_offset
    movw $0x1000, dap_buffer_segment
    movl $KERNEL_LBA, dap_start_lba
    movl $0, dap_start_lba + 4

    call read_disk_sectors
    jc disk_read_error

    call validate_kernel_header
    jc kernel_header_error

    movw $kernel_header_ok_message, %si
    call print_string

    call read_kernel_metadata
    jc unsupported_kernel_error

    call print_kernel_metadata

    # Načítanie celej real-mode setup časti kernelu.
    call load_kernel_setup
    jc disk_read_error

    movw $kernel_setup_loaded_message, %si
    call print_string

    call enable_a20

    movw $a20_message, %si
    call print_string

    # --------------------------------------------------------
    # Načítanie hlavnej časti kernelu na 0x00100000
    # --------------------------------------------------------

    movw $kernel_loading_message, %si
    call print_string

    movzwl kernel_setup_sector_count, %eax
    addl $KERNEL_LBA, %eax
    movl %eax, current_lba

    movl kernel_syssize, %eax

    # syssize je uvedený v 16-bajtových jednotkách.
    # Jeden 512-bajtový sektor obsahuje 32 takých jednotiek.
    addl $31, %eax
    shrl $5, %eax
    movl %eax, remaining_sectors

    movl $KERNEL_ADDRESS, current_destination

    movb $0, progress_counter

    call load_high_memory_region
    jc disk_read_error

    movw $done_message, %si
    call print_string

    # --------------------------------------------------------
    # Načítanie initramfs na 0x08000000
    # --------------------------------------------------------

    movw $initramfs_loading_message, %si
    call print_string

    movl $INITRAMFS_LBA, current_lba

    movl $INITRAMFS_SIZE, %eax
    addl $511, %eax
    shrl $9, %eax
    movl %eax, remaining_sectors

    movl $INITRAMFS_ADDRESS, current_destination

    movb $0, progress_counter

    call load_high_memory_region
    jc disk_read_error

    movw $done_message, %si
    call print_string

    # Vytvoríme kernel command line.
    call install_command_line

    # Zapíšeme údaje bootloadera do setup headera.
    call configure_kernel_header

    movw $starting_kernel_message, %si
    call print_string

    # Odovzdanie riadenia real-mode setup časti Linuxu.
    call start_linux_kernel


stop:
    cli
    hlt
    jmp stop


# ============================================================
# E820 mapa pamäte
# ============================================================

get_e820_memory_map:
    xorw %ax, %ax
    movw %ax, %es

    movw $0x9000, %di
    xorl %ebx, %ebx
    movw $0, memory_entry_count

e820_next_entry:
    movl $1, %es:20(%di)

    movl $0xe820, %eax
    movl $0x534d4150, %edx
    movl $24, %ecx

    int $0x15
    jc e820_failed

    cmpl $0x534d4150, %eax
    jne e820_failed

    incw memory_entry_count
    addw $24, %di

    cmpw $32, memory_entry_count
    jae e820_finished

    testl %ebx, %ebx
    jnz e820_next_entry

e820_finished:
    xorw %ax, %ax
    movw %ax, %es
    clc
    ret

e820_failed:
    xorw %ax, %ax
    movw %ax, %es
    stc
    ret


# ============================================================
# BIOS LBA čítanie
# ============================================================

read_disk_sectors:
    pushw %ds

    xorw %ax, %ax
    movw %ax, %ds

    movw $disk_address_packet, %si
    movb boot_drive, %dl
    movb $0x42, %ah

    int $0x13

    popw %ds
    ret


# ============================================================
# Kontrola kernel hlavičky
# ============================================================

validate_kernel_header:
    movw $0x1000, %ax
    movw %ax, %es

    cmpw $0xaa55, %es:0x1fe
    jne invalid_kernel_header

    cmpl $0x53726448, %es:0x202
    jne invalid_kernel_header

    clc
    ret

invalid_kernel_header:
    stc
    ret


# ============================================================
# Načítanie údajov z kernel hlavičky
# ============================================================

read_kernel_metadata:
    movw $0x1000, %ax
    movw %ax, %es

    movb %es:0x1f1, %al
    xorb %ah, %ah

    testw %ax, %ax
    jnz setup_sector_count_available

    movw $4, %ax

setup_sector_count_available:
    incw %ax
    movw %ax, kernel_setup_sector_count

    movw %es:0x206, %ax
    movw %ax, kernel_protocol_version

    movb %es:0x211, %al
    movb %al, kernel_load_flags

    movl %es:0x1f4, %eax
    movl %eax, kernel_syssize

    cmpw $0x0200, kernel_protocol_version
    jb unsupported_kernel

    testb $0x01, kernel_load_flags
    jz unsupported_kernel

    clc
    ret

unsupported_kernel:
    stc
    ret


# ============================================================
# Výpis kernel metadata
# ============================================================

print_kernel_metadata:
    movw $kernel_protocol_message, %si
    call print_string

    movw kernel_protocol_version, %ax
    call print_hex16

    movw $newline, %si
    call print_string

    movw $setup_sectors_message, %si
    call print_string

    movw kernel_setup_sector_count, %ax
    call print_hex16

    movw $newline, %si
    call print_string

    movw $load_flags_message, %si
    call print_string

    xorb %ah, %ah
    movb kernel_load_flags, %al
    call print_hex16

    movw $newline, %si
    call print_string

    ret


# ============================================================
# Načítanie kernel setup časti
# ============================================================

load_kernel_setup:
    movw kernel_setup_sector_count, %ax
    movw %ax, dap_sector_count

    movw $0, dap_buffer_offset
    movw $0x1000, dap_buffer_segment

    movl $KERNEL_LBA, dap_start_lba
    movl $0, dap_start_lba + 4

    call read_disk_sectors
    ret


# ============================================================
# Načítanie dát nad 1 MiB
# ============================================================

load_high_memory_region:
load_high_memory_next_chunk:
    movl remaining_sectors, %eax
    testl %eax, %eax
    jz load_high_memory_finished

    cmpl $MAX_READ_SECTORS, %eax
    jbe use_remaining_sector_count

    movw $MAX_READ_SECTORS, current_chunk_sectors
    jmp chunk_sector_count_ready

use_remaining_sector_count:
    movw %ax, current_chunk_sectors

chunk_sector_count_ready:
    movw current_chunk_sectors, %ax
    movw %ax, dap_sector_count

    movw $0, dap_buffer_offset
    movw $BOUNCE_SEGMENT, dap_buffer_segment

    movl current_lba, %eax
    movl %eax, dap_start_lba
    movl $0, dap_start_lba + 4

    call read_disk_sectors
    jc load_high_memory_failed

    # BIOS mohol zmeniť segmentový cache, preto unreal mode
    # obnovíme po každom BIOS čítaní.
    call enter_unreal_mode

    call copy_bounce_buffer_to_high_memory

    movzwl current_chunk_sectors, %eax

    subl %eax, remaining_sectors
    addl %eax, current_lba

    shll $9, %eax
    addl %eax, current_destination

    incb progress_counter
    andb $0x0f, progress_counter
    jnz load_high_memory_next_chunk

    movb $'.', %al
    call print_character

    jmp load_high_memory_next_chunk

load_high_memory_finished:
    clc
    ret

load_high_memory_failed:
    stc
    ret


# ============================================================
# Kopírovanie bounce buffera
# ============================================================

copy_bounce_buffer_to_high_memory:
    xorl %esi, %esi
    movl current_destination, %edi

    movzwl current_chunk_sectors, %ecx

    # Jeden sektor má 512 bajtov = 128 dwordov.
    shll $7, %ecx

copy_bounce_next_dword:
    movl %gs:(%esi), %eax
    movl %eax, %fs:(%edi)

    addl $4, %esi
    addl $4, %edi

    decl %ecx
    jnz copy_bounce_next_dword

    ret


# ============================================================
# A20
# ============================================================

enable_a20:
    inb $0x92, %al
    orb $0x02, %al
    andb $0xfe, %al
    outb %al, $0x92
    ret


# ============================================================
# Unreal mode
# ============================================================
#
# FS dostane 4 GiB limit a používa sa na zápis do high memory.
# GS ukazuje na bounce buffer 0x50000.
#

enter_unreal_mode:
    cli

    lgdt gdt_descriptor

    movl %cr0, %eax
    orl $0x01, %eax
    movl %eax, %cr0

    ljmp $0x08, $protected_mode_entry

protected_mode_entry:
    movw $0x10, %ax
    movw %ax, %fs

    movl %cr0, %eax
    andl $0xfffffffe, %eax
    movl %eax, %cr0

    ljmp $0x0000, $unreal_mode_ready

unreal_mode_ready:
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    movw $BOUNCE_SEGMENT, %ax
    movw %ax, %gs

    sti
    ret


# ============================================================
# Kernel command line
# ============================================================

install_command_line:
    movw $kernel_command_line, %si

    movw $0x2000, %ax
    movw %ax, %es

    xorw %di, %di

copy_command_line:
    lodsb
    stosb

    testb %al, %al
    jnz copy_command_line

    xorw %ax, %ax
    movw %ax, %es

    ret


# ============================================================
# Nastavenie Linux setup headera
# ============================================================

configure_kernel_header:
    movw $0x1000, %ax
    movw %ax, %es

    # Bootloader nemá pridelené oficiálne ID.
    movb $0xff, %es:0x210

    # CAN_USE_HEAP
    orb $0x80, %es:0x211

    # heap_end = 0xE000, pole obsahuje heap_end - 0x200
    movw $0xde00, %es:0x224

    # Kernel command line
    movl $COMMAND_LINE_ADDRESS, %es:0x228

    # Initramfs
    movl $INITRAMFS_ADDRESS, %es:0x218
    movl $INITRAMFS_SIZE, %es:0x21c

    # Normálny textový režim.
    movw $0xffff, %es:0x1fa

    xorw %ax, %ax
    movw %ax, %es

    ret


# ============================================================
# Spustenie Linux real-mode setup kódu
# ============================================================

start_linux_kernel:
    cli

    movw $0x1000, %ax

    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    movw $0xe000, %sp

    # Setup entry point je 512 bajtov od začiatku obrazu:
    # 0x10000 + 0x200 = 0x10200
    ljmp $0x1020, $0x0000


# ============================================================
# Sériový port COM1
# ============================================================

serial_init:
    # Zakáž UART interrupts.
    movw $0x3f9, %dx
    movb $0x00, %al
    outb %al, %dx

    # Zapni DLAB.
    movw $0x3fb, %dx
    movb $0x80, %al
    outb %al, %dx

    # Divisor 1 = 115200 baud.
    movw $0x3f8, %dx
    movb $0x01, %al
    outb %al, %dx

    movw $0x3f9, %dx
    movb $0x00, %al
    outb %al, %dx

    # 8 bitov, bez parity, jeden stop bit.
    movw $0x3fb, %dx
    movb $0x03, %al
    outb %al, %dx

    # FIFO.
    movw $0x3fa, %dx
    movb $0xc7, %al
    outb %al, %dx

    # RTS + DTR.
    movw $0x3fc, %dx
    movb $0x0b, %al
    outb %al, %dx

    ret


serial_write:
    pushw %ax
    pushw %dx

    movb %al, %ah

serial_wait:
    movw $0x3fd, %dx
    inb %dx, %al

    testb $0x20, %al
    jz serial_wait

    movw $0x3f8, %dx
    movb %ah, %al
    outb %al, %dx

    popw %dx
    popw %ax
    ret


# ============================================================
# Výpis
# ============================================================

print_string:
    lodsb

    testb %al, %al
    jz print_string_finished

    call print_character
    jmp print_string

print_string_finished:
    ret


print_character:
    pushw %ax
    pushw %bx

    call serial_write

    outb %al, $0xe9

    movb $0x0e, %ah
    movb $0x00, %bh
    int $0x10

    popw %bx
    popw %ax
    ret


print_hex16:
    pushw %ax
    pushw %bx
    pushw %cx

    movw %ax, %bx
    movw $4, %cx

print_hex16_next_digit:
    rolw $4, %bx

    movb %bl, %al
    andb $0x0f, %al

    cmpb $10, %al
    jb print_hex16_number

    addb $('A' - 10), %al
    jmp print_hex16_output

print_hex16_number:
    addb $'0', %al

print_hex16_output:
    call print_character
    loop print_hex16_next_digit

    popw %cx
    popw %bx
    popw %ax
    ret


# ============================================================
# Chyby
# ============================================================

e820_error:
    movw $e820_error_message, %si
    call print_string
    jmp stop

disk_read_error:
    movw $disk_error_message, %si
    call print_string
    jmp stop

kernel_header_error:
    movw $kernel_header_error_message, %si
    call print_string
    jmp stop

unsupported_kernel_error:
    movw $unsupported_kernel_message, %si
    call print_string
    jmp stop


# ============================================================
# Premenné
# ============================================================

memory_entry_count:
    .word 0

kernel_setup_sector_count:
    .word 0

kernel_protocol_version:
    .word 0

kernel_load_flags:
    .byte 0

boot_drive:
    .byte 0

kernel_syssize:
    .long 0

current_lba:
    .long 0

remaining_sectors:
    .long 0

current_destination:
    .long 0

current_chunk_sectors:
    .word 0

progress_counter:
    .byte 0


# ============================================================
# Disk Address Packet
# ============================================================

.balign 4

disk_address_packet:
    .byte 0x10
    .byte 0x00

dap_sector_count:
    .word 0

dap_buffer_offset:
    .word 0

dap_buffer_segment:
    .word 0

dap_start_lba:
    .quad 0


# ============================================================
# GDT
# ============================================================

.balign 8

gdt_start:
    # Null descriptor
    .quad 0x0000000000000000

    # Selector 0x08: 16-bit code, base 0, limit 64 KiB
    .word 0xffff
    .word 0x0000
    .byte 0x00
    .byte 0x9a
    .byte 0x00
    .byte 0x00

    # Selector 0x10: 32-bit data, base 0, limit 4 GiB
    .word 0xffff
    .word 0x0000
    .byte 0x00
    .byte 0x92
    .byte 0xcf
    .byte 0x00

gdt_end:

gdt_descriptor:
    .word gdt_end - gdt_start - 1
    .long gdt_start


# ============================================================
# Texty
# ============================================================

welcome_message:
    .asciz "IT LAMA Bootloader 0.2.0\r\n"

e820_message:
    .asciz "E820 entries: 0x"

kernel_header_ok_message:
    .asciz "Linux bzImage header OK.\r\n"

kernel_protocol_message:
    .asciz "Boot protocol: 0x"

setup_sectors_message:
    .asciz "Setup sectors total: 0x"

load_flags_message:
    .asciz "Load flags: 0x"

kernel_setup_loaded_message:
    .asciz "Linux setup loaded at 0x10000.\r\n"

a20_message:
    .asciz "A20 enabled.\r\n"

kernel_loading_message:
    .asciz "Loading Linux kernel "

initramfs_loading_message:
    .asciz "Loading initramfs "

done_message:
    .asciz " done.\r\n"

starting_kernel_message:
    .asciz "Starting Linux kernel...\r\n"

e820_error_message:
    .asciz "ERROR: E820 memory map failed.\r\n"

disk_error_message:
    .asciz "ERROR: BIOS disk read failed.\r\n"

kernel_header_error_message:
    .asciz "ERROR: Invalid Linux bzImage header.\r\n"

unsupported_kernel_message:
    .asciz "ERROR: Unsupported Linux kernel.\r\n"

newline:
    .asciz "\r\n"


# ============================================================
# Rocky Linux kernel command line
# ============================================================

kernel_command_line:
    .asciz "BOOT_IMAGE=/vmlinuz root=/dev/mapper/rlm-root ro rd.lvm.lv=rlm/root rd.lvm.lv=rlm/swap resume=UUID=c4be146d-5590-485f-be0e-400485956eeb console=tty0"
