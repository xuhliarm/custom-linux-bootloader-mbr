#  Lama Bootloader

My experimental x86 BIOS bootloader written in GNU assembly.

It has two stages. Stage 1 is loaded by the BIOS, stage 2 loads a Linux
`bzImage` and initramfs from fixed disk sectors and starts the Linux real-mode
setup code.

This started as a project for learning how Linux actually boots. It currently
boots my Rocky Linux 10 VM without GRUB.

## Current limitations

- legacy x86 BIOS only
- kernel and initramfs must each occupy one continuous disk extent
- disk LBAs and kernel command line are build-time values
- no menu, filesystem driver, Secure Boot or UEFI support
- experimental; a wrong install command can make a machine unbootable

## Build

Requirements: GNU `as`, GNU `ld`, `make`.

```sh
make
```

The binaries are written to `build/`.

Example with the values used by my Rocky VM:

```sh
make clean
make KERNEL_LBA=399736 \
     INITRAMFS_LBA=719928 \
     INITRAMFS_SIZE=38746088
```

The boot flow is:

```text
BIOS -> stage 1 -> stage 2 -> Linux kernel -> initramfs -> root filesystem
```
