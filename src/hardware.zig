// The LC-3 has 65,536 memory locations
// (the maximum that is addressable by a 16-bit unsigned integer 2^16)
pub var memory: [1 << 16]u16 = undefined;

// The LC-3 has 10 total registers, each of which is 16 bits.
// 8 general purpose registers (R0-R7)
// 1 program counter (PC) register
// 1 condition flags (COND)
pub const Registers = enum(u16) {
    R_R0 = 0,
    R_R1,
    R_R2,
    R_R3,
    R_R4,
    R_R5,
    R_R6,
    R_R7,
    R_PC,
    R_COND,
    R_COUNT,
};

// Storing the registers in an array
pub var reg: [@enumToInt(Registers.R_COUNT)]u16 = undefined;

// Each opcode represents one task that the CPU “knows” how to do.
// There are just 16 opcodes in LC-3.
// Everything the computer can calculate is some sequence of these simple instructions.
// Each instruction is 16 bits long, with the left 4 bits storing the opcode.
// The rest of the bits are used to store the parameters.
pub const Opcodes = enum(u16) {
    OP_BR = 0, // branch
    OP_ADD, // add
    OP_LD, // load
    OP_ST, // store
    OP_JSR, // jump register
    OP_AND, // bitwise and
    OP_LDR, // load register
    OP_STR, // store register
    OP_RTI, // unused
    OP_NOT, // bitwise not
    OP_LDI, // load indirect
    OP_STI, // store indirect
    OP_JMP, // jump
    OP_RES, // reserved (unused)
    OP_LEA, // load effective address
    OP_TRAP, // execute trap
};

// Each CPU has a variety of condition flags to signal various situations.
// The LC-3 uses only 3 condition flags which indicate the sign of the previous calculation.
pub const Flags = enum(u16) {
    FL_POS = 1 << 0, // P
    FL_ZRO = 1 << 1, // Z
    FL_NEG = 1 << 2, // N
};

// The LC-3 provides a few predefined routines for performing common tasks and interacting with I/O devices.
// For example, there are routines for getting input from the keyboard and for displaying strings to the console.
// These are called trap routines which you can think of as the operating system or API for the LC-3.
// Each trap routine is assigned a trap code which identifies it (similar to an opcode).
// To execute one, the TRAP instruction is called with the trap code of the desired routine.
pub const Traps = enum(u16) {
    TRAP_GETC = 0x20, // get character from keyboard, not echoed onto the terminal
    TRAP_OUT = 0x21, // output a character
    TRAP_PUTS = 0x22, // output a word string
    TRAP_IN = 0x23, // get character from keyboard, echoed onto the terminal
    TRAP_PUTSP = 0x24, // output a byte string
    TRAP_HALT = 0x25, // halt the program
};

// The LC-3 has two memory mapped registers that need to be implemented.
// They are the keyboard status register (KBSR) and keyboard data register (KBDR).
// The KBSR indicates whether a key has been pressed, and the KBDR identifies which key was pressed.
pub const MemoryMappedRegisters = enum(u16) {
    MR_KBSR = 0xFE00, // keyboard status
    MR_KBDR = 0xFE02, // keyboard data
};
