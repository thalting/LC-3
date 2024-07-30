const hardware = @import("hardware.zig");
const util = @import("util.zig");
const std = @import("std");
const os = std.posix;
const mem = std.mem;

pub fn main() !void {
    if (std.os.argv.len < 2) {
        std.log.info("usage: lc3 [image-file1] ...", .{});
        os.exit(1);
    }

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |img| {
        util.readImage(img) catch |e| {
            std.log.err("failed to load image {s}: {s}", .{ img, @errorName(e) });
            os.exit(1);
        };
    }

    // Setup
    try os.sigaction(os.SIG.INT, &.{ .handler = .{ .handler = util.handleInterrupt }, .mask = undefined, .flags = undefined }, null);
    try util.disableInputBuffering();
    defer util.restoreInputBuffering() catch {};

    // since exactly one condition flag should be set at any given time, set the Z flag
    hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_ZRO);
    // set the PC to default starting position
    hardware.reg[@intFromEnum(hardware.Registers.R_PC)] = 0x3000;

    var running: bool = true;

    while (running) {
        // FETCH
        const instr: u16 = util.memRead(hardware.reg[@intFromEnum(hardware.Registers.R_PC)]);
        const op: hardware.Opcodes = @enumFromInt(instr >> 12);
        hardware.reg[@intFromEnum(hardware.Registers.R_PC)] += 1;

        switch (op) {
            .OP_ADD => {
                // destination hardware.register (DR)
                const r0: u16 = (instr >> 9) & 0x7;
                // first operand (SR1)
                const r1: u16 = (instr >> 6) & 0x7;
                // whether we are in immediate mode
                const imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag == 1) {
                    const imm5: u16 = util.signExtend(instr & 0x1F, 5);
                    hardware.reg[r0] = hardware.reg[r1] +% imm5;
                } else {
                    const r2: u16 = instr & 0x7;
                    hardware.reg[r0] = hardware.reg[r1] +% hardware.reg[r2];
                }

                util.updateFlags(r0);
            },
            .OP_AND => {
                const r0: u16 = (instr >> 9) & 0x7;
                const r1: u16 = (instr >> 6) & 0x7;
                const imm_flag: u16 = (instr >> 5) & 0x1;

                if (imm_flag == 1) {
                    const imm5: u16 = util.signExtend(instr & 0x1F, 5);
                    hardware.reg[r0] = hardware.reg[r1] & imm5;
                } else {
                    const r2: u16 = instr & 0x7;
                    hardware.reg[r0] = hardware.reg[r1] & hardware.reg[r2];
                }
                util.updateFlags(r0);
            },
            .OP_NOT => {
                const r0: u16 = (instr >> 9) & 0x7;
                const r1: u16 = (instr >> 6) & 0x7;

                hardware.reg[r0] = ~hardware.reg[r1];
                util.updateFlags(r0);
            },
            .OP_BR => {
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);
                const cond_flag: u16 = (instr >> 9) & 0x7;

                if (cond_flag & hardware.reg[@intFromEnum(hardware.Registers.R_COND)] != 0) {
                    hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +%= pc_offset;
                }
            },
            .OP_JMP => {
                // Also handles RET
                const r1: u16 = (instr >> 6) & 0x7;
                hardware.reg[@intFromEnum(hardware.Registers.R_PC)] = hardware.reg[r1];
            },
            .OP_JSR => {
                const long_flag: u16 = (instr >> 11) & 1;
                hardware.reg[@intFromEnum(hardware.Registers.R_R7)] = hardware.reg[@intFromEnum(hardware.Registers.R_PC)];

                if (long_flag == 1) {
                    const long_pc_offset: u16 = util.signExtend(instr & 0x7FF, 11);
                    hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +%= long_pc_offset; // JSR
                } else {
                    const r1: u16 = (instr >> 6) & 0x7;
                    hardware.reg[@intFromEnum(hardware.Registers.R_PC)] = hardware.reg[r1]; // JSRR
                }
            },
            .OP_LD => {
                const r0: u16 = (instr >> 9) & 0x7;
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);

                hardware.reg[r0] = util.memRead(hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +% pc_offset);
                util.updateFlags(r0);
            },
            .OP_LDI => {
                // destination hardware.register (DR)
                const r0: u16 = (instr >> 9) & 0x7;
                // PCoffset 9
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);
                // add pc_offset to the current PC, look at that hardware.memory location to get the final address
                hardware.reg[r0] = util.memRead(util.memRead(hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +% pc_offset));
                util.updateFlags(r0);
            },
            .OP_LDR => {
                const r0: u16 = (instr >> 9) & 0x7;
                const r1: u16 = (instr >> 6) & 0x7;
                const offset: u16 = util.signExtend(instr & 0x3F, 6);

                hardware.reg[r0] = util.memRead(hardware.reg[r1] +% offset);
                util.updateFlags(r0);
            },
            .OP_LEA => {
                const r0: u16 = (instr >> 9) & 0x7;
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);
                hardware.reg[r0] = hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +% pc_offset;
                util.updateFlags(r0);
            },
            .OP_ST => {
                const r0: u16 = (instr >> 9) & 0x7;
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);
                util.memWrite(hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +% pc_offset, hardware.reg[r0]);
            },
            .OP_STI => {
                const r0: u16 = (instr >> 9) & 0x7;
                const pc_offset: u16 = util.signExtend(instr & 0x1FF, 9);
                util.memWrite(util.memRead(hardware.reg[@intFromEnum(hardware.Registers.R_PC)] +% pc_offset), hardware.reg[r0]);
            },
            .OP_STR => {
                const r0: u16 = (instr >> 9) & 0x7;
                const r1: u16 = (instr >> 6) & 0x7;
                const offset: u16 = util.signExtend(instr & 0x3F, 6);
                util.memWrite(hardware.reg[r1] +% offset, hardware.reg[r0]);
            },
            .OP_TRAP => {
                hardware.reg[@intFromEnum(hardware.Registers.R_R7)] = hardware.reg[@intFromEnum(hardware.Registers.R_PC)];

                switch (@as(hardware.Traps, @enumFromInt(instr & 0xFF))) {
                    .TRAP_GETC => {
                        hardware.reg[@intFromEnum(hardware.Registers.R_R0)] = try std.io.getStdIn().reader().readByte();
                        util.updateFlags(@intFromEnum(hardware.Registers.R_R0));
                    },
                    .TRAP_OUT => {
                        try std.io.getStdOut().writer().writeByte(@truncate(hardware.reg[@intFromEnum(hardware.Registers.R_R0)]));
                    },
                    .TRAP_PUTS => {
                        const str = mem.sliceTo(hardware.memory[hardware.reg[@intFromEnum(hardware.Registers.R_R0)]..], 0);
                        for (str) |*ch16| {
                            try std.io.getStdOut().writer().writeByte(@truncate(ch16.*));
                        }
                    },
                    .TRAP_IN => {
                        try std.io.getStdOut().writer().print("Enter a character: ", .{});
                        const c: u8 = try std.io.getStdIn().reader().readByte();
                        try std.io.getStdOut().writer().print("{c}", .{c});
                        hardware.reg[@intFromEnum(hardware.Registers.R_R0)] = c;
                        util.updateFlags(@intFromEnum(hardware.Registers.R_R0));
                    },
                    .TRAP_PUTSP => {
                        const str = mem.sliceTo(hardware.memory[hardware.reg[@intFromEnum(hardware.Registers.R_R0)]..], 0);
                        for (mem.sliceAsBytes(str)) |*ch8| {
                            try std.io.getStdOut().writer().writeByte(ch8.*);
                        }
                    },
                    .TRAP_HALT => {
                        try std.io.getStdOut().writer().print("HALT\n", .{});
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
