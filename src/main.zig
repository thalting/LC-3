const std = @import("std");
const os = std.os;
const fs = std.fs;
const mem = std.mem;

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

const Keyboard = enum(u16) {
    MR_KBSR = 0xFE00, // keyboard status
    MR_KBDR = 0xFE02, // keyboard data
};

fn memWrite(address: u16, val: u16) void {
    memory[address] = val;
}

fn memRead(address: u16) u16 {
    if (address == @enumToInt(Keyboard.MR_KBSR)) {
        if (checkKey()) {
            memory[@enumToInt(Keyboard.MR_KBSR)] = (1 << 15);
            memory[@enumToInt(Keyboard.MR_KBDR)] = std.io.getStdIn().reader().readByte() catch 0;
        } else {
            memory[@enumToInt(Keyboard.MR_KBSR)] = 0;
        }
    }
    return memory[address];
}

fn signExtend(val: u16, comptime bit_count: u16) u16 {
    var extended: u16 = val;
    // When negative sign, extend with 1's to maintain "negative" values.
    if (extended & (1 << bit_count - 1) > 0) {
        extended |= @truncate(u16, (0xFFFF << bit_count));
        return extended;
    }
    return extended;
}

fn updateFlags(r: u16) void {
    if (reg[r] == 0) {
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_ZRO);
    } else if (reg[r] >> 15 != 0) { // a 1 in the left-most bit indicates negative
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_NEG);
    } else {
        reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_POS);
    }
}

var original_tio: os.termios = undefined;
fn disableInputBuffering() !void {
    original_tio = try os.tcgetattr(0);
    var new_tio = original_tio;
    new_tio.lflag &= ~os.system.ICANON & ~os.system.ECHO;
    try os.tcsetattr(0, os.TCSA.NOW, new_tio);
}

fn restoreInputBuffering() !void {
    try os.tcsetattr(0, os.TCSA.NOW, original_tio);
}

fn handleInterrupt(signal: c_int) callconv(.C) void {
    restoreInputBuffering() catch {};
    std.log.info("killed by signal: {}", .{signal});
    os.exit(2);
}

fn checkKey() bool {
    var poll_stdin = [_]os.pollfd{.{
        .fd = 0,
        .events = os.POLL.IN,
        .revents = undefined,
    }};
    _ = os.poll(&poll_stdin, 0) catch return false;
    return poll_stdin[0].revents & os.POLL.IN > 0;
}

fn readImage(path: []const u8) !void {
    const img_file = try fs.cwd().openFile(path, .{});
    defer img_file.close();
    const reader = img_file.reader();
    var orig = try reader.readIntBig(u16);
    while (reader.readIntBig(u16) catch |e| switch (e) {
        error.EndOfStream => null,
        else => return e,
    }) |content| : (orig += 1) {
        if (orig >= memory.len) return error.FileTooBig;
        memory[orig] = content;
    }
}

pub fn main() !void {
    // Load arguments
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var arg_it = try std.process.ArgIterator.initWithAllocator(gpa.allocator());
        defer arg_it.deinit();
        var found_img = false;
        _ = arg_it.skip();
        while (arg_it.next()) |img| {
            readImage(img) catch |e| {
                std.log.err("failed to load image {s}: {s}", .{ img, @errorName(e) });
                os.exit(1);
            };
            found_img = true;
        }
        if (!found_img) {
            std.log.info("usage: lc3 [image-file1] ...", .{});
            os.exit(1);
        }
    }

    // Setup
    try os.sigaction(os.SIG.INT, &.{ .handler = .{ .handler = handleInterrupt }, .mask = undefined, .flags = undefined }, null);
    try disableInputBuffering();
    defer restoreInputBuffering() catch {};

    // since exactly one condition flag should be set at any given time, set the Z flag
    reg[@enumToInt(Registers.R_COND)] = @enumToInt(Flags.FL_ZRO);
    // set the PC to default starting position
    reg[@enumToInt(Registers.R_PC)] = 0x3000;

    var running: bool = true;

    while (running) {
        // FETCH
        var instr: u16 = memRead(reg[@enumToInt(Registers.R_PC)]);
        var op: Opcodes = @intToEnum(Opcodes, instr >> 12);
        reg[@enumToInt(Registers.R_PC)] += 1;

        switch (op) {
            .OP_ADD => {
                // destination register (DR)
                var r0: u16 = (instr >> 9) & 0x7;
                // first operand (SR1)
                var r1: u16 = (instr >> 6) & 0x7;
                // whether we are in immediate mode
                var imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag == 1) {
                    var imm5: u16 = signExtend(instr & 0x1F, 5);
                    reg[r0] = reg[r1] +% imm5;
                } else {
                    var r2: u16 = instr & 0x7;
                    reg[r0] = reg[r1] +% reg[r2];
                }

                updateFlags(r0);
            },
            .OP_AND => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag == 1) {
                    var imm5: u16 = signExtend(instr & 0x1F, 5);
                    reg[r0] = reg[r1] & imm5;
                } else {
                    var r2: u16 = instr & 0x7;
                    reg[r0] = reg[r1] & reg[r2];
                }
                updateFlags(r0);
            },
            .OP_NOT => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;

                reg[r0] = ~reg[r1];
                updateFlags(r0);
            },
            .OP_BR => {
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);
                var cond_flag: u16 = (instr >> 9) & 0x7;

                if (cond_flag & reg[@enumToInt(Registers.R_COND)] != 0) {
                    reg[@enumToInt(Registers.R_PC)] +%= pc_offset;
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

                if (long_flag == 1) {
                    var long_pc_offset: u16 = signExtend(instr & 0x7FF, 11);
                    reg[@enumToInt(Registers.R_PC)] +%= long_pc_offset; // JSR
                } else {
                    var r1: u16 = (instr >> 6) & 0x7;
                    reg[@enumToInt(Registers.R_PC)] = reg[r1]; // JSRR
                }
            },
            .OP_LD => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);

                reg[r0] = memRead(reg[@enumToInt(Registers.R_PC)] +% pc_offset);
                updateFlags(r0);
            },
            .OP_LDI => {
                // destination register (DR)
                var r0: u16 = (instr >> 9) & 0x7;
                // PCoffset 9
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);
                // add pc_offset to the current PC, look at that memory location to get the final address
                reg[r0] = memRead(memRead(reg[@enumToInt(Registers.R_PC)] +% pc_offset));
                updateFlags(r0);
            },
            .OP_LDR => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var offset: u16 = signExtend(instr & 0x3F, 6);

                reg[r0] = memRead(reg[r1] +% offset);
                updateFlags(r0);
            },
            .OP_LEA => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);
                reg[r0] = reg[@enumToInt(Registers.R_PC)] +% pc_offset;
                updateFlags(r0);
            },
            .OP_ST => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);
                memWrite(reg[@enumToInt(Registers.R_PC)] +% pc_offset, reg[r0]);
            },
            .OP_STI => {
                var r0: u16 = (instr >> 9) & 0x7;
                var pc_offset: u16 = signExtend(instr & 0x1FF, 9);
                memWrite(memRead(reg[@enumToInt(Registers.R_PC)] +% pc_offset), reg[r0]);
            },
            .OP_STR => {
                var r0: u16 = (instr >> 9) & 0x7;
                var r1: u16 = (instr >> 6) & 0x7;
                var offset: u16 = signExtend(instr & 0x3F, 6);
                memWrite(reg[r1] +% offset, reg[r0]);
            },
            .OP_TRAP => {
                reg[@enumToInt(Registers.R_R7)] = reg[@enumToInt(Registers.R_PC)];

                switch (@intToEnum(Traps, instr & 0xFF)) {
                    .TRAP_GETC => {
                        reg[@enumToInt(Registers.R_R0)] = try std.io.getStdIn().reader().readByte();
                        updateFlags(@enumToInt(Registers.R_R0));
                    },
                    .TRAP_OUT => {
                        try std.io.getStdOut().writer().writeByte(@truncate(u8, reg[@enumToInt(Registers.R_R0)]));
                    },
                    .TRAP_PUTS => {
                        const str = mem.sliceTo(memory[reg[@enumToInt(Registers.R_R0)]..], 0);
                        for (str) |ch16| {
                            try std.io.getStdOut().writer().writeByte(@truncate(u8, ch16));
                        }
                    },
                    .TRAP_IN => {
                        try std.io.getStdOut().writer().print("Enter a character: ", .{});
                        var c: u8 = try std.io.getStdIn().reader().readByte();
                        try std.io.getStdOut().writer().print("{c}", .{c});
                        reg[@enumToInt(Registers.R_R0)] = c;
                        updateFlags(@enumToInt(Registers.R_R0));
                    },
                    .TRAP_PUTSP => {
                        const str = mem.sliceTo(memory[reg[@enumToInt(Registers.R_R0)]..], 0);
                        for (mem.sliceAsBytes(str)) |ch8| {
                            try std.io.getStdOut().writer().writeByte(ch8);
                        }
                    },
                    .TRAP_HALT => {
                        try std.io.getStdOut().writer().print("HALT", .{});
                        running = false;
                    },
                }
            },
            .OP_RES, .OP_RTI => {
                os.exit(127);
            },
        }
    }
}
