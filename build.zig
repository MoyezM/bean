const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("bean", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Benchmarks are always built optimized, whatever `-Doptimize` says.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // A client that drives a store with the workloads of RocksDB's db_bench.
    // Like the benchmarks, it is always built optimized.
    const bean_bench = b.addExecutable(.{
        .name = "bean-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bean_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(bean_bench);
    const run_bean_bench = b.addRunArtifact(bean_bench);
    // Flags given after `--` on the command line go to the client.
    run_bean_bench.addPassthruArgs();

    // Measures whether durable writes through the asynchronous I/O layer
    // leave the caller free. Linux only.
    const async_io_bench = b.addExecutable(.{
        .name = "async-io-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/async_io_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_async_io_bench = b.addRunArtifact(async_io_bench);
    run_async_io_bench.addPassthruArgs();

    const async_io_bench_step = b.step("async-io-bench", "Measure durable writes through the asynchronous I/O layer; pass a directory after --");
    async_io_bench_step.dependOn(&run_async_io_bench.step);

    const bean_bench_step = b.step("bean-bench", "Run the db_bench-style client; pass its flags after --");
    bean_bench_step.dependOn(&run_bean_bench.step);
}
