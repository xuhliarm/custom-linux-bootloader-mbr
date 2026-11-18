.code16
.section .text
.global _start

_start:
    cli

    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp

    sti

    # BIOS odovzdáva číslo bootovacieho disku v DL.
    movb %dl, boot_drive

    movw $stage1_message, %si
    call print_string

    # INT 13h/AH=42h: rozšírené BIOS LBA čítanie.
    movw $disk_address_packet, %si
    movb boot_drive, %dl
    movb $0x42, %ah
    int $0x13

    jc disk_error

    # Stage 2 očakáva bootovací disk opäť v DL.
    movb boot_drive, %dl

    # Stage 2 sme načítali na fyzickú adresu 0x8000.
    ljmp $0x0000, $0x8000


disk_error:
    movw $disk_error_message, %si
    call print_string

stop:
    cli
    hlt
    jmp stop


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

    # QEMU debug port.
    outb %al, $0xe9

    # BIOS obrazovka.
    movb $0x0e, %ah
    movb $0x00, %bh
    int $0x10

    popw %bx
    popw %ax
    ret


boot_drive:
    .byte 0


.balign 4

# 16-bajtový Disk Address Packet.
disk_address_packet:
    .byte 0x10
    .byte 0x00
    .word 8              # načítať 8 sektorov
    .word 0x8000         # cieľový offset
    .word 0x0000         # cieľový segment
    .quad 2048           # začiatok /dev/sda1


stage1_message:
    .asciz "IT LAMA Bootloader stage 1\r\n"

disk_error_message:
    .asciz "ERROR: Cannot load stage 2\r\n"


.org 510
.word 0xaa55
