const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const ArrayList = std.ArrayList;

const path_boringssl = "boringssl";

fn withBase(alloc: mem.Allocator, base: []const u8, name: []const u8) !ArrayList(u8) {
    var path = ArrayList(u8).init(alloc);
    try path.appendSlice(base);
    try path.append(fs.path.sep);
    try path.appendSlice(name);
    return path;
}

fn buildErrData(alloc: mem.Allocator, lib: *std.build.LibExeObjStep, base: []const u8) !void {
    const out_name = "err_data_generate.c";

    var dir = try fs.cwd().makeOpenPath(base, .{});
    defer dir.close();
    var fd = try dir.createFile(out_name, .{});
    defer fd.close();

    var arena = heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var child = std.ChildProcess.init(
        &.{ "go", "run", path_boringssl ++ "/crypto/err/err_data_generate.go" },
        arena.allocator(),
    );
    child.stdout_behavior = .Pipe;
    try child.spawn();
    try fd.writeFileAll(child.stdout.?, .{});
    _ = try child.wait();

    const path = try withBase(arena.allocator(), base, out_name);
    lib.addCSourceFile(path.items, &.{});
}

fn addDir(alloc: mem.Allocator, lib: *std.build.LibExeObjStep, base: []const u8) !void {
    var dir = try fs.cwd().openIterableDir(base, .{});
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |file| {
        if (!mem.eql(u8, fs.path.extension(file.name), ".c")) {
            continue;
        }
        var arena = heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const path = try withBase(arena.allocator(), base, file.name);
        lib.addCSourceFile(path.items, &.{});
    }
}

fn addSubdirs(alloc: mem.Allocator, lib: *std.build.LibExeObjStep, base: []const u8) !void {
    var dir = try fs.cwd().openIterableDir(base, .{});
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |file| {
        if (file.kind != .Directory) {
            continue;
        }
        var arena = heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const path = try withBase(arena.allocator(), base, file.name);
        try addDir(arena.allocator(), lib, path.items);
    }
}

pub fn build(b: *std.build.Builder) !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary("crypto", null);
    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.strip = true;
    lib.linkLibC();
    lib.install();
    if (mode == .ReleaseSmall) {
        lib.defineCMacro("OPENSSL_SMALL", null);
    }

    lib.defineCMacro("ARCH", "generic");
    lib.defineCMacro("OPENSSL_NO_ASM", null);

    if (target.os_tag) |tag| {
        if (tag == .wasi) {
            lib.defineCMacro("OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED", null);
            lib.defineCMacro("SO_KEEPALIVE", "0");
            lib.defineCMacro("SO_ERROR", "0");
            lib.defineCMacro("FREEBSD_GETRANDOM", null);
            lib.defineCMacro("getrandom(a,b,c)", "getentropy(a,b)|b");
            lib.defineCMacro("GRND_NONBLOCK", "0");
        }
    }

    lib.addIncludePath(path_boringssl ++ fs.path.sep_str ++ "include");
    const base_crypto = path_boringssl ++ fs.path.sep_str ++ "crypto";
    const base_generated = "generated";
    try buildErrData(gpa.allocator(), lib, base_generated);
    try addDir(gpa.allocator(), lib, base_crypto);
    try addSubdirs(gpa.allocator(), lib, base_crypto);
}
