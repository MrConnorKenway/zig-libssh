const std = @import("std");

// Structure to hold compile command entry
const CompileCommand = struct {
    directory: []const u8,
    command: []const u8,
    file: []const u8,
    output: ?[]const u8 = null,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("libssh", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("main.zig"),
        .link_libc = true,
    });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the real path of libssh we depend on and call cmake under its build
    // root path to generate `compile_commands.json`.
    const upstream = b.dependency("libssh", .{});
    var upstream_root_str = upstream.builder.build_root.path.?;
    const upstream_root_dir = try std.fs.openDirAbsolute(upstream_root_str, .{});
    upstream_root_str = try upstream_root_dir.realpathAlloc(allocator, ".");
    defer allocator.free(upstream_root_str);
    const current_build_dir = try std.fs.openDirAbsolute(b.build_root.path.?, .{});
    const current_build_path = try current_build_dir.realpathAlloc(allocator, ".");
    defer allocator.free(current_build_path);
    current_build_dir.access("build/compile_commands.json", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const argv = &[_][]const u8{
                "cmake",
                "-B",
                "build",
                "-DCMAKE_EXPORT_COMPILE_COMMANDS=1",
                "-S",
                upstream_root_str,
            };
            const argv_str = try std.mem.join(allocator, " ", argv);
            defer allocator.free(argv_str);
            std.log.info("{s}\n", .{argv_str});
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = argv,
                .cwd = current_build_path,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            switch (result.term) {
                .Exited => |exit_code| {
                    std.log.info("\n{s}\n", .{result.stdout});
                    if (exit_code != 0) {
                        std.log.err("\n{s}\n", .{result.stderr});
                    }
                },
                else => {
                    std.log.err("cmake terminated unexpectedly {s}", .{@tagName(result.term)});
                    return err;
                },
            }
        },
        else => {
            return err;
        },
    };

    // Try to open and read compile_commands.json
    const file = try current_build_dir.openFile("build/compile_commands.json", .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    const parsed = try std.json.parseFromSlice([]CompileCommand, allocator, content, .{});
    defer parsed.deinit();

    const comp_cmd_entries = parsed.value;

    for (comp_cmd_entries) |entry| {
        if (std.mem.indexOf(u8, entry.file, "src")) |_| {
            var flags = try std.ArrayList([]const u8).initCapacity(allocator, 64);
            defer flags.deinit();
            var iter = std.mem.splitScalar(u8, entry.command, ' ');
            var ignore = true;
            while (iter.next()) |flag| {
                if (ignore) {
                    ignore = false;
                    continue;
                } else if (std.mem.eql(u8, flag, "-o") or std.mem.eql(u8, flag, "-c")) {
                    ignore = true;
                    continue;
                }
                try flags.append(flag);
            }
            if (!std.mem.startsWith(u8, entry.file, upstream_root_str)) {
                const msg = try std.fmt.allocPrint(allocator, "UnexpectedFilePath: file '{s}' is not under cwd '{s}'", .{ entry.file, upstream_root_str });
                @panic(msg);
            }
            module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{entry.file[upstream_root_str.len + 1 ..]},
                .flags = flags.items,
            });
        }
    }

    module.addIncludePath(upstream.path("include"));
    module.addIncludePath(b.path("build/include"));

    module.linkSystemLibrary("crypto", .{});
    module.linkSystemLibrary("ssl", .{});
    module.linkSystemLibrary("z", .{});
}
