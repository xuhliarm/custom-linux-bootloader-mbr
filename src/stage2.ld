OUTPUT_FORMAT(binary)
ENTRY(stage2_start)

SECTIONS
{
    . = 0x8000;

    .text : {
        *(.text)
    }

    /DISCARD/ : {
        *(.note.gnu.property)
        *(.comment)
    }
}
