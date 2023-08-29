const hardware = @import("hardware.zig");
const std = @import("std");
const os = std.os;
const fs = std.fs;

pub fn memWrite(address: u16, val: u16) void {
    hardware.memory[address] = val;
}

pub fn memRead(address: u16) u16 {
    if (address == @intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)) {
        if (checkKey()) {
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)] = (1 << 15);
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBDR)] = std.io.getStdIn().reader().readByte() catch 0;
        } else {
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)] = 0;
        }
    }
    return hardware.memory[address];
}

pub fn signExtend(val: u16, comptime bit_count: u16) u16 {
    var extended: u16 = val;
    // When negative sign, extend with 1's to maintain "negative" values.
    if (extended & (1 << bit_count - 1) > 0) {
        extended |= @truncate(0xFFFF << bit_count);
    }
    return extended;
}

pub fn updateFlags(r: u16) void {
    if (hardware.reg[r] == 0) {
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_ZRO);
    } else if (hardware.reg[r] >> 15 != 0) { // a 1 in the left-most bit indicates negative
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_NEG);
    } else {
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_POS);
    }
}

var original_tio: os.termios = undefined;
pub fn disableInputBuffering() !void {
    original_tio = try os.tcgetattr(0);
    var new_tio = original_tio;
    new_tio.lflag &= ~os.system.ICANON & ~os.system.ECHO;
    try os.tcsetattr(0, os.TCSA.NOW, new_tio);
}

pub fn restoreInputBuffering() !void {
    try os.tcsetattr(0, os.TCSA.NOW, original_tio);
}

pub fn handleInterrupt(signal: c_int) callconv(.C) void {
    restoreInputBuffering() catch {};
    _ = signal;
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

pub fn readImage(path: []const u8) !void {
    const img_file = try fs.cwd().openFile(path, .{});
    defer img_file.close();
    const reader = img_file.reader();
    var orig = try reader.readIntBig(u16);
    while (@as(?u16, reader.readIntBig(u16) catch |e| switch (e) {
        error.EndOfStream => null,
        else => return e,
    })) |content| : (orig += 1) {
        if (orig >= hardware.memory.len) return error.FileTooBig;
        hardware.memory[orig] = content;
    }
}
