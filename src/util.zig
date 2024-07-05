const hardware = @import("hardware.zig");
const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const stdin = std.io.getStdIn();

pub inline fn memWrite(address: u16, val: u16) void {
    hardware.memory[address] = val;
}

pub inline fn memRead(address: u16) u16 {
    if (address == @intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)) {
        if (checkKey()) {
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)] = (1 << 15);
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBDR)] = stdin.reader().readByte() catch 0;
        } else {
            hardware.memory[@intFromEnum(hardware.MemoryMappedRegisters.MR_KBSR)] = 0;
        }
    }
    return hardware.memory[address];
}

pub inline fn signExtend(val: u16, comptime bit_count: u16) u16 {
    var extended: u16 = val;
    // When negative sign, extend with 1's to maintain "negative" values.
    if (extended & (1 << bit_count - 1) > 0) {
        extended |= @truncate(0xFFFF << bit_count);
    }
    return extended;
}

pub inline fn updateFlags(r: u16) void {
    if (hardware.reg[r] == 0) {
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_ZRO);
    } else if (hardware.reg[r] >> 15 != 0) { // a 1 in the left-most bit indicates negative
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_NEG);
    } else {
        hardware.reg[@intFromEnum(hardware.Registers.R_COND)] = @intFromEnum(hardware.Flags.FL_POS);
    }
}

var original_termios: posix.termios = undefined;
pub fn disableInputBuffering() !void {
    original_termios = try posix.tcgetattr(stdin.handle);

    var termios = original_termios;
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;

    try posix.tcsetattr(stdin.handle, .NOW, termios);
}

pub inline fn restoreInputBuffering() !void {
    try posix.tcsetattr(stdin.handle, .NOW, original_termios);
}

pub fn handleInterrupt(signal: i32) callconv(.C) void {
    restoreInputBuffering() catch {};
    _ = signal;
    posix.exit(2);
}

inline fn checkKey() bool {
    var poll_stdin = [_]posix.pollfd{.{
        .fd = stdin.handle,
        .events = posix.POLL.IN,
        .revents = undefined,
    }};
    _ = posix.poll(&poll_stdin, 0) catch return false;
    return poll_stdin[0].revents & posix.POLL.IN > 0;
}

pub inline fn readImage(path: []const u8) !void {
    const img_file = try fs.cwd().openFile(path, .{});
    defer img_file.close();
    const reader = img_file.reader();
    var orig = try reader.readInt(u16, .big);
    while (@as(?u16, reader.readInt(u16, .big) catch |e| switch (e) {
        error.EndOfStream => null,
        else => return e,
    })) |content| : (orig += 1) {
        if (orig >= hardware.memory.len) return error.FileTooBig;
        hardware.memory[orig] = content;
    }
}
