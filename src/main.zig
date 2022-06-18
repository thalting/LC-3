const std = @import("std");
const os = std.os;
const c = @cImport({
    @cInclude("termios.h");
});

// The LC-3 has 65,536 memory locations
// (the maximum that is addressable by a 16-bit unsigned integer 2^16)
var memory: [1 << 16]u16 = undefined;

// The LC-3 has 10 total registers, each of which is 16 bits.
// 8 general purpose registers (R0-R7)
// 1 program counter (PC) register
// 1 condition flags (COND)
const Registers = enum(u16) {
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
var reg: [@enumToInt(Registers.R_COUNT)]u16 = undefined;

const Opcodes = enum(u16) {
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

const Flags = enum(u16) {
    FL_POS = 1 << 0, // P
    FL_ZRO = 1 << 1, // Z
    FL_NEG = 1 << 2, // N
};
const Traps = enum(u16) {
    TRAP_GETC = 0x20, // get character from keyboard, not echoed onto the terminal
    TRAP_OUT = 0x21, // output a character
    TRAP_PUTS = 0x22, // output a word string
    TRAP_IN = 0x23, // get character from keyboard, echoed onto the terminal
    TRAP_PUTSP = 0x24, // output a byte string
    TRAP_HALT = 0x25, // halt the program
};

const Bar = enum(u16) {
    MR_KBSR = 0xFE00, // keyboard status
    MR_KBDR = 0xFE02, // keyboard data
};

fn mem_write(address: u16, val: u16) void {
    memory[address] = val;
}

fn mem_read(address: u16) u16 {
    if (address == Bar.MR_KBSR) {
        if (check_key()) {
            memory[@enumToInt(Bar.MR_KBSR)] = (1 << 15);
            // TODO:
            // memory[@enumToInt(Bar.MR_KBDR)] = getchar();
        } else {
            memory[@enumToInt(Bar.MR_KBSR)] = 0;
        }
    }
    return memory[address];
}

fn sign_extend(x: u16, bit_count: i32) u16 {
    if ((x >> (bit_count - 1)) & 1) {
        x |= (0xFFFF << bit_count);
    }
    return x;
}

fn update_flags(r: u16) void {
    if (reg[r] == 0) {
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_ZRO);
    } else if (reg[r] >> 15) { // a 1 in the left-most bit indicates negative
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_NEG);
    } else {
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_POS);
    }
}

// TODO: use zig std
var original_tio: c.termios = undefined;
fn disable_input_buffering() void {
    const stdin_fd = std.os.linux.STDIN_FILENO;
    _ = c.tcgetattr(stdin_fd, &original_tio);
    var new_tio: c.termios = original_tio;
    new_tio.c_lflag &= @bitCast(c_uint, ~c.ICANON & ~c.ECHO);
    _ = c.tcsetattr(stdin_fd, c.TCSANOW, &new_tio);
}

// TODO: use zig std
fn restore_input_buffering() void {
    const stdin_fd = std.os.linux.STDIN_FILENO;
    _ = c.tcsetattr(stdin_fd, c.TCSANOW, &original_tio);
}

pub fn main() void {
    // Load arguments
    const argv: [][*:0]u8 = os.argv;
    if (argv.len < 2) {
        std.debug.print("lc3 [image-file1] ...\n", .{});
        os.exit(2);
    }
    const argc: i32 = argv.len;
    var j: i32 = 1;
    while (j < argc) : (j += 1) {
        // not implemented
        if (!read_image(argv[j])) {
            std.debug.print("failed to load image: {s}\n", argv[j]);
            os.exit(1);
        }
    }
    // Setup

    // since exactly one condition flag should be set at any given time, set the Z flag
    reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_ZRO);
    // set the PC to starting position
    // 0x3000 is the default
    const Foo = enum(u16) { PC_START = 0x3000 };
    reg[@enumToInt(Registers.R_PC)] = @enumToInt(Foo.PC_START);
    std.debug.print("{any}\n", .{reg});

    var running: bool = true;

    while (running) {
        // FETCH
        var instr: u16 = mem_read(reg[@enumToInt(Registers.R_PC)] + 1);
        var op: u16 = @intToEnum(Opcodes, instr >> 12);

        switch (op) {
            .OP_ADD => {

                // destination register (DR)
                var r0: u16 = (instr >> 9) & 0x7;
                // first operand (SR1)
                var r1: u16 = (instr >> 6) & 0x7;
                // whether we are in immediate mode
                var imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag) {
                    var imm5: u16 = sing_extend(instr & 0x1F, 5);
                    reg[r0] = reg[r1] + imm5;
                } else {
                    var r2: u16 = instr & 0x7;
                    reg[r0] = reg[r1] + reg[r2];
                }

                update_flags(r0);
            },
            .OP_AND => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag) {
                    var imm5: u16 = sign_extend(instr & 0x1F, 5);
                    reg[r0] = reg[r1] & imm5;
                } else {
                    var r2: u16 = instr & 0x7;
                    reg[r0] = reg[r1] & reg[r2];
                }
                update_flags(r0);
            },
            .OP_NOT => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;

                reg[r0] = ~reg[r1];
                update_flags(r0);
            },
            .OP_BR => {
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);
                var cond_flag: u16 = (instr >> 9) & 0x7;

                if (cond_flag & reg[@enumToInt(Registers.R_COND)]) {
                    reg[@enumToInt(Registers.R_PC)] += pc_offset;
                }
            },
            .OP_JMP => {
                // Also handles RET
                var r1: u16 = (instr >> 6) & 0x7;
                reg[@enumToInt(Registers.R_PC)] = reg[r1];
            },
            .OP_JSR => {
                var long_flag: u16 = (instr >> 11) & 1;
                reg[@enumToInt(Registers.R_R7)] = reg[@enumToInt(Registers.R_PC)];

                if (long_flag) {
                    var long_pc_offset: u16 = sing_extend(instr & 0x7FF, 11);
                    reg[@enumToInt(Registers.R_PC)] += long_pc_offset; // JSR
                } else {
                    var r1: u16 = (instr >> 6) & 0x7;
                    reg[@enumToInt(Registers.R_PC)] = reg[r1]; // JSRR
                }
                break;
            },
            .OP_LD => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);

                reg[r0] = mem_read(reg[@enumToInt(Registers.R_PC)] + pc_offset);
                update_flags(r0);
            },
            .OP_LDI => {
                // destination register (DR)
                var r0: u16 = (instr >> 9) & 0x7;
                // PCoffset 9
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);
                // add pc_offset to the current PC, look at that memory location to get the final address
                reg[r0] = mem_read(mem_read(reg[@enumToInt(Registers.R_PC)] + pc_offset));
                update_flags(r0);
            },
            .OP_LDR => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var offset: u16 = sign_extend(instr & 0x3F, 6);

                reg[r0] = mem_read(reg[r1] + offset);
                update_flags(r0);
            },
            .OP_LEA => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);
                reg[r0] = reg[@enumToInt(Registers.R_PC)] + pc_offset;
                update_flags(r0);
            },
            .OP_ST => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);
                mem_write(reg[@enumToInt(Registers.R_PC)] + pc_offset, reg[r0]);
            },
            .OP_STI => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = sign_extend(instr & 0x1FF, 9);
                mem_write(mem_read(reg[@enumToInt(Registers.R_PC)] + pc_offset), reg[r0]);
            },
            .OP_STR => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var offset: u16 = sign_extend(instr & 0x3F, 6);
                mem_write(reg[r1] + offset, reg[r0]);
            },
            .OP_TRAP => {
                reg[@enumToInt(Registers.R_R7)] = reg[@enumToInt(Registers.R_PC)];

                switch (@intToEnum(Traps, instr & 0xFF)) {
                    .TRAP_GETC => {
                        // TODO: no casting?
                        reg[@enumToInt(Registers.R_R0)] = std.io.getStdIn().reader().readByte();
                        update_flags(@enumToInt(Registers.R_R0));
                    },
                    .TRAP_OUT => {
                        try std.io.getStdOut().writer().print("{c}", reg[@enumToInt(Registers.R_R0)]);
                    },
                    .TRAP_PUTS => {
                        // one char per word
                        var c: *i16 = memory + reg[@enumToInt(Registers.R_R0)];

                        while (*c) : (c += 1) {
                            try std.io.getStdOut().writer().print("{c}", *c);
                        }
                    },
                    .TRAP_IN => {
                        std.debug.print("Enter a character: ", .{});
                        var c: u8 = std.io.getStdIn().reader().readByte();
                        try std.io.getStdOut().writer().print("{c}", c);
                        reg[@enumToInt(Registers.R_R0)] = c;
                        update_flags(@enumToInt(Registers.R_R0));
                    },
                    .TRAP_PUTSP => {
                        // one char per byte (two bytes per word)
                        // here we need to swap back to
                        // big endian format
                        var c: *u16 = memory + reg[@enumToInt(Registers.R_R0)];

                        while (*c) : (c += 1) {
                            var char1: u8 = *c & 0xFF;
                            try std.io.getStdOut().writer().print("{c}", char1);
                            var char2: u8 = *c >> 8;

                            if (char2) {
                                try std.io.getStdOut().writer().print("{c}", char2);
                            }
                        }
                    },
                    .TRAP_HALT => {
                        std.debug.print("HALT");
                        running = false;
                    },
                }
            },
            // TODO: implement
            // .OP_RES => {},
            // .OP_RTI => {},
            else => {
                exit(127);
            },
        }
    }
}
