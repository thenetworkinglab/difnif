/* DifNif FPGA-only firmware: everything in the SoC's 8 KB of RAM */
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 8K }
ENTRY(_start)
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
