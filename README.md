# LAMA linux Bootloader

> [!CAUTION]
> **EXPERIMENTAL LEARNING PROJECT. DO NOT TRY THIS ON A PHYSICAL OR PRODUCTION
> MACHINE.** The installation commands overwrite boot sectors directly and can
> destroy data or make the system unbootable. Use only a disposable virtual
> machine, create a snapshot first, and keep a tested rescue path. You have been
> warned. :)

My experimental two-stage x86 BIOS bootloader written in GNU assembly. The
project started as a way to understand what happens between the BIOS and the
Linux kernel. It currently boots my Rocky Linux 10 VM without GRUB.

## Boot flow

```text
BIOS
  -> stage 1 in the MBR
  -> stage 2 in the BIOS boot partition
  -> Linux bzImage
  -> initramfs
  -> root filesystem
```

## Why there are two stages

The legacy BIOS reads only the first 512-byte sector of the boot disk and runs
it at physical address `0x7c00`.

That sector is not fully available to our code:

```text
bytes 0-439     boot code
bytes 440-445   disk signature and reserved bytes
bytes 446-509   MBR partition table
bytes 510-511   boot signature 55 aa
```

Stage 1 therefore has to remain very small. It initializes the real-mode
segments and stack, remembers the BIOS boot-drive number from `DL`, uses BIOS
`INT 13h/AH=42h` to read eight sectors, and jumps to stage 2 at address
`0x8000`.

Stage 2 has more room. It:

- reads the BIOS E820 memory map;
- validates the Linux `bzImage` header;
- reads the Linux boot-protocol fields;
- enables A20;
- uses a low-memory bounce buffer and unreal mode to copy data above 1 MiB;
- loads the protected-mode kernel at `0x00100000`;
- loads initramfs at `0x08000000`;
- installs the kernel command line;
- fills the required setup-header fields;
- jumps to the Linux real-mode setup entry point.

## Repository layout

```text
.
├── Makefile
├── README.md
└── src
    ├── stage1.S
    ├── stage1.ld
    ├── stage2.S
    └── stage2.ld
```

`as` translates each assembly source into an ELF relocatable object. `ld` uses
the linker scripts to place the code at the expected memory address and emits
flat binary files that the BIOS can load directly.

## Requirements

Tested with Rocky Linux 10 on x86-64 in legacy BIOS mode.

```sh
sudo dnf install binutils make qemu-kvm
```

Check the firmware mode and architecture:

```sh
uname -m
test -d /sys/firmware/efi && echo UEFI || echo BIOS
```

The current implementation expects `x86_64` and `BIOS`.

## Build

The important build-time values are:

- `STAGE2_LBA`: first sector occupied by stage 2;
- `KERNEL_LBA`: first sector of the contiguous kernel file;
- `INITRAMFS_LBA`: first sector of the contiguous initramfs file;
- `INITRAMFS_SIZE`: exact initramfs size in bytes.

Example for one specific test VM:

```sh
make clean
make STAGE2_LBA=2048 \
     KERNEL_LBA=399736 \
     INITRAMFS_LBA=719928 \
     INITRAMFS_SIZE=38746088
```

Verify the results:

```sh
stat -c '%n %s bytes' build/stage1.bin build/stage2.bin
od -An -tx1 -j510 -N2 build/stage1.bin
```

Expected properties:

```text
stage1.bin is exactly 512 bytes
stage2.bin is at most 4096 bytes
the final two stage1 bytes are 55 aa
```

The example LBAs belong to one VM. Never copy them to another disk.

## Safe QEMU experiment

This creates a standalone raw image and does not write to a real disk.

Select matching kernel and initramfs files:

```sh
KERNEL_IMAGE="/boot/vmlinuz-$(uname -r)"
INITRAMFS_IMAGE="/boot/initramfs-$(uname -r).img"
INITRAMFS_SIZE=$(stat -c '%s' "$INITRAMFS_IMAGE")
```

Use fixed positions inside the test image:

```sh
STAGE2_LBA=2048
KERNEL_LBA=4096
INITRAMFS_LBA=65536
```

Build with the same values:

```sh
make clean
make STAGE2_LBA="$STAGE2_LBA" \
     KERNEL_LBA="$KERNEL_LBA" \
     INITRAMFS_LBA="$INITRAMFS_LBA" \
     INITRAMFS_SIZE="$INITRAMFS_SIZE"
```

Create a 128 MiB sparse image and copy the raw components to their LBAs:

```sh
cp build/stage1.bin build/itlama-disk.img
truncate -s 128M build/itlama-disk.img

dd if=build/stage2.bin of=build/itlama-disk.img \
   bs=512 seek="$STAGE2_LBA" conv=notrunc status=none

dd if="$KERNEL_IMAGE" of=build/itlama-disk.img \
   bs=512 seek="$KERNEL_LBA" conv=notrunc status=progress

dd if="$INITRAMFS_IMAGE" of=build/itlama-disk.img \
   bs=512 seek="$INITRAMFS_LBA" conv=notrunc status=progress
```

`seek=N` starts output after `N` blocks. With `bs=512`, the byte offset is
`N * 512`. `conv=notrunc` prevents `dd` from truncating the rest of the image.

Run the image with QEMU software emulation:

```sh
/usr/libexec/qemu-kvm \
  -accel tcg \
  -cpu max \
  -m 256M \
  -drive file=build/itlama-disk.img,format=raw,if=ide,index=0,media=disk \
  -boot order=c \
  -display none \
  -monitor none \
  -serial stdio \
  -no-reboot \
  -no-shutdown
```

For serial kernel output, the command line in `src/stage2.S` must contain:

```text
console=ttyS0,115200n8
```

The kernel and initramfs should start. Unless QEMU also has the expected root
disk, dracut will eventually wait for a missing root device. That is normal for
this test.

## Dangerous: installing on a BIOS/GPT VM

> [!DANGER]
> Everything below is destructive. It replaces the existing MBR boot code and
> data in the BIOS boot partition. Use only a snapshotted disposable VM.

The example assumes:

```text
/dev/sda     boot disk
/dev/sda1    1 MiB BIOS boot partition
/dev/sda2    /boot filesystem
```

Confirm the actual layout:

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE,START,MOUNTPOINTS
fdisk -l /dev/sda
```

Do not continue unless the system uses legacy BIOS mode and the selected disk
has a BIOS boot partition.

### 1. Create dedicated kernel and initramfs copies

```sh
KERNEL_IMAGE="/boot/vmlinuz-$(uname -r)"
INITRAMFS_IMAGE="/boot/initramfs-$(uname -r).img"

cp --reflink=never "$KERNEL_IMAGE" /boot/itlama-vmlinuz
cp --reflink=never "$INITRAMFS_IMAGE" /boot/itlama-initramfs.img
sync
```

The loader does not understand XFS. It reads the files through physical disk
sectors, so each dedicated file must occupy one continuous extent:

```sh
filefrag -v -b512 /boot/itlama-vmlinuz
filefrag -v -b512 /boot/itlama-initramfs.img
```

Both commands must report `1 extent found`. Stop if either file is fragmented.

### 2. Calculate absolute LBAs

`filefrag` reports physical offsets relative to the `/boot` partition. Add the
start sector of that partition:

```sh
BOOT_PARTITION=/dev/sda2
BOOT_PARTITION_START=$(lsblk -no START "$BOOT_PARTITION")
echo "$BOOT_PARTITION_START"
```

Example values:

```text
kernel physical offset:    395640
initramfs physical offset: 715832
/dev/sda2 start:              4096
```

Calculate the absolute LBAs:

```sh
KERNEL_LBA=$((4096 + 395640))
INITRAMFS_LBA=$((4096 + 715832))

echo "$KERNEL_LBA"
echo "$INITRAMFS_LBA"
```

The example produces `399736` and `719928`.

### 3. Verify the raw sectors

Never trust the arithmetic without comparing raw disk data to the files:

```sh
KERNEL_SIZE=$(stat -c '%s' /boot/itlama-vmlinuz)
INITRAMFS_SIZE=$(stat -c '%s' /boot/itlama-initramfs.img)

dd if=/dev/sda bs=512 skip="$KERNEL_LBA" status=none | \
  cmp -n "$KERNEL_SIZE" - /boot/itlama-vmlinuz && \
  echo "Kernel LBA OK"

dd if=/dev/sda bs=512 skip="$INITRAMFS_LBA" status=none | \
  cmp -n "$INITRAMFS_SIZE" - /boot/itlama-initramfs.img && \
  echo "Initramfs LBA OK"
```

Both `LBA OK` messages are required.

Prevent the filesystem from replacing or moving the dedicated files:

```sh
chattr +i /boot/itlama-vmlinuz /boot/itlama-initramfs.img
lsattr /boot/itlama-*
```

The `i` attribute means immutable. Even root must use `chattr -i` before
replacing these files.

### 4. Build for the real disk

The BIOS boot partition in this example begins at LBA 2048:

```sh
STAGE2_LBA=2048

make clean
make STAGE2_LBA="$STAGE2_LBA" \
     KERNEL_LBA="$KERNEL_LBA" \
     INITRAMFS_LBA="$INITRAMFS_LBA" \
     INITRAMFS_SIZE="$INITRAMFS_SIZE"

stat -c '%n %s bytes' build/stage1.bin build/stage2.bin
od -An -tx1 -j510 -N2 build/stage1.bin
```

Before installation, make sure the kernel command line in `src/stage2.S`
matches the target system. The Rocky Linux example uses an LVM root:

```text
root=/dev/mapper/rlm-root ro rd.lvm.lv=rlm/root
```

Use `console=tty0` for the VM display or `console=ttyS0,115200n8` for a serial
console.

### 5. Back up the existing boot area

In this example `/dev/sda2` begins exactly 2 MiB from the start of the disk.
The backup therefore contains the MBR, primary GPT metadata and BIOS boot
partition, but not the `/boot` filesystem:

```sh
dd if=/dev/sda \
   of=/root/itlama-preinstall-sda-first-2MiB.img \
   bs=1M count=2 status=progress

sync
stat -c '%s bytes' /root/itlama-preinstall-sda-first-2MiB.img
sha256sum /root/itlama-preinstall-sda-first-2MiB.img
```

The expected size is `2097152` bytes. Store another copy outside the VM.

### 6. Install stage 2

Pad stage 2 to the eight sectors that stage 1 reads:

```sh
cp build/stage2.bin build/stage2-install.bin
truncate -s 4096 build/stage2-install.bin
```

The next command overwrites the beginning of the BIOS boot partition and
replaces the GRUB core image stored there:

```sh
dd if=build/stage2-install.bin of=/dev/sda1 \
   bs=512 count=8 conv=notrunc status=progress

sync

cmp -n 4096 build/stage2-install.bin /dev/sda1 && \
  echo "Stage 2 installed OK"
```

### 7. Install stage 1

Only the first 440 bytes are written. This preserves the disk signature,
protective MBR partition entry and existing `55 aa` signature:

```sh
dd if=build/stage1.bin of=/dev/sda \
   bs=1 count=440 conv=notrunc status=progress

sync

cmp -n 440 build/stage1.bin /dev/sda && \
  echo "Stage 1 installed OK"

od -An -tx1 -j510 -N2 /dev/sda
fdisk -l /dev/sda
```

The signature must still be `55 aa` and the GPT partitions must still exist.

### 8. Reboot

Keep the VM console and snapshot available, then reboot:

```sh
reboot
```

Expected output:

```text
IT LAMA Bootloader stage 1
IT LAMA Bootloader 0.2.0
Linux bzImage header OK.
Loading Linux kernel ... done.
Loading initramfs ... done.
Starting Linux kernel...
```

## Restoring the previous boot area

If the VM no longer boots, start a rescue environment and restore the saved
first 2 MiB to the same disk:

```sh
dd if=/root/itlama-preinstall-sda-first-2MiB.img \
   of=/dev/sda bs=1M count=2 conv=notrunc status=progress
sync
```

Verify the device name first. This restores the old MBR, GPT metadata and BIOS
boot partition, including the previous GRUB data.

## Updating the kernel

The bootloader does not automatically follow distribution kernel updates. A
new kernel or initramfs can occupy different physical sectors.

The update procedure is:

1. remove immutable attributes with `chattr -i`;
2. replace the dedicated kernel and initramfs copies;
3. verify that each file has one extent;
4. calculate and verify the new absolute LBAs;
5. rebuild stage 2 with the new values and initramfs size;
6. reinstall stage 2 in the BIOS boot partition;
7. restore immutable attributes with `chattr +i`.

Stage 1 does not change while stage 2 remains at the same LBA.

## Current limitations

- legacy x86 BIOS only;
- no UEFI or Secure Boot;
- no filesystem reader;
- kernel and initramfs must each have one contiguous extent;
- fixed build-time disk locations;
- no boot menu or fallback kernel;
- tested only in virtual machines.

