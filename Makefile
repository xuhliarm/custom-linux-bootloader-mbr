AS      := as
LD      := ld

BUILD   := build
SRC     := src

STAGE2_LBA      ?= 2048
KERNEL_LBA      ?= 4096
INITRAMFS_LBA   ?= 65536
INITRAMFS_SIZE  ?= 38746088

.PHONY: all clean

all: $(BUILD)/stage1.bin $(BUILD)/stage2.bin

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/stage1.o: $(SRC)/stage1.S | $(BUILD)
	$(AS) --32 --defsym STAGE2_LBA=$(STAGE2_LBA) -o $@ $<

$(BUILD)/stage1.bin: $(BUILD)/stage1.o $(SRC)/stage1.ld
	$(LD) -m elf_i386 -T $(SRC)/stage1.ld -o $@ $<
	@test "$$(stat -c %s $@)" -eq 512

$(BUILD)/stage2.o: $(SRC)/stage2.S | $(BUILD)
	$(AS) --32 \
		--defsym KERNEL_LBA=$(KERNEL_LBA) \
		--defsym INITRAMFS_LBA=$(INITRAMFS_LBA) \
		--defsym INITRAMFS_SIZE=$(INITRAMFS_SIZE) \
		-o $@ $<

$(BUILD)/stage2.bin: $(BUILD)/stage2.o $(SRC)/stage2.ld
	$(LD) -m elf_i386 -T $(SRC)/stage2.ld -o $@ $<
	@test "$$(stat -c %s $@)" -le 4096

clean:
	rm -rf $(BUILD)
