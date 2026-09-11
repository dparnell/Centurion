; Does a HLT (opcode 0x00) park the microcode in the 0x71f..0x73d loop?
        .org $8000
        .byte $01
start:  NOP
        NOP
        .byte $00
        NOP
