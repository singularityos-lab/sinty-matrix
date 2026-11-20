const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto = b.createModule(.{ .root_source_file = b.path("proto/proto.zig") });

    const mcu = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
    });
    const fw_mod = b.createModule(.{
        .root_source_file = b.path("firmware/uno-q/main.zig"),
        .target = mcu,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "proto", .module = b.createModule(.{ .root_source_file = b.path("proto/proto.zig"), .target = mcu, .optimize = .ReleaseSmall }) }},
        .single_threaded = true,
        .strip = false,
    });
    const fw = b.addExecutable(.{ .name = "uno-q", .root_module = fw_mod });
    fw.setLinkerScript(b.path("firmware/uno-q/link.ld"));
    fw.entry = .{ .symbol_name = "reset" };
    const fw_bin = fw.addObjCopy(.{ .format = .bin });
    const fw_install = b.addInstallFile(fw_bin.getOutput(), "share/sinty-matrix/uno-q.bin");
    const fw_step = b.step("firmware", "build the microcontroller firmware");
    fw_step.dependOn(&fw_install.step);

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("daemon/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "proto", .module = proto }},
    });
    const opts = b.addOptions();
    opts.addOption(u16, "firmware_version", firmwareVersion(b));
    daemon_mod.addOptions("build_options", opts);
    const daemon = b.addExecutable(.{ .name = "sinty-matrixd", .root_module = daemon_mod });
    b.getInstallStep().dependOn(&b.addInstallArtifact(daemon, .{ .dest_dir = .{ .override = .{ .custom = "libexec" } } }).step);
    b.getInstallStep().dependOn(&fw_install.step);

    const tests = b.step("test", "run the unit tests");
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("proto/proto.zig"), .target = target }) })).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = daemon_mod })).step);
}

fn firmwareVersion(b: *std.Build) u16 {
    const src = b.build_root.handle.readFileAlloc(b.graph.io, "firmware/uno-q/main.zig", b.allocator, .limited(1 << 20)) catch @panic("firmware source missing");
    const key = "pub const firmware_version: u16 = ";
    const at = std.mem.indexOf(u8, src, key) orelse @panic("firmware version missing");
    const rest = src[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse @panic("firmware version malformed");
    return std.fmt.parseInt(u16, rest[0..end], 10) catch @panic("firmware version malformed");
}
