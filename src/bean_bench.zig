//! bean-bench: drives a bean store with the workloads of RocksDB's
//! `db_bench`, so that the two can be run with the same flags and compared.
//!
//!     zig build bean-bench -- --benchmarks=fillseq,readrandom --num=50000
//!
//! The flags, the key layout, the workloads and the result lines follow
//! `db_bench`:
//!
//!     --benchmarks=a,b,c    workloads to run, in order (see `Benchmark`)
//!     --num=N               number of keys
//!     --reads=N             number of reads; defaults to `--num`
//!     --key_size=N          bytes in each key, at least 8
//!     --value_size=N        bytes in each value
//!     --batch_size=N        operations in each write batch
//!     --writes=N            writes each thread makes in a write workload;
//!                           defaults to `--num`. Keys picked at random
//!                           still come from the first `num`
//!     --threads=N           threads that work at once. Each writes `writes`
//!                           keys one at a time, or does `reads` lookups
//!     --seek_nexts=N        entries read after each seek in `seekrandom`
//!     --duration=N          stop a workload of random reads or writes after
//!                           N seconds, if it has not finished by then
//!     --histogram=1         time every operation, and print the spread of
//!                           the times after the workload's result
//!     --seed=N              seed for the random keys
//!     --db=PATH             directory of the store
//!     --use_existing_db=1   keep the store's contents for `fillseq` and
//!                           `fillrandom`, which otherwise start from empty
//!
//! The store itself is single-threaded. With `--threads` above 1 the client
//! puts a group committer in front of it (`bench_group_commit.zig`), which
//! gathers the threads' writes into one batch for each sync and keeps
//! readers out while a batch is written. That batching is the client's, not
//! the store's.
//!
//! Four things differ from `db_bench`. Every write batch is synced to disk
//! before the write returns, because bean has no unsynced mode, which is
//! what `db_bench --sync=1` does. A store holds at most `kv.tables_max`
//! tables until compaction is built, so a workload that fills it stops early
//! and says so. With `--histogram=1` the times are exact, where `db_bench`
//! counts them in buckets of whole microseconds and estimates within a
//! bucket. And with `--duration` a workload still stops at its count of
//! operations, where `db_bench` then ignores the count; give a count the
//! workload will not reach to have the time alone decide. With
//! `--histogram=1` room is set aside to time every one of those operations,
//! eight bytes each, so the count cannot be made as large as you like.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const GroupCommitter = @import("bench_group_commit.zig").GroupCommitter;
const kv = @import("kv.zig");
const write_batch = @import("write_batch.zig");
const WriteBatch = write_batch.WriteBatch;

/// The longest key the store accepts.
const key_size_max = write_batch.key_size_max;

/// The longest value the store accepts.
const value_size_max = write_batch.value_size_max;

/// A key starts with its number as eight big-endian bytes, as in `db_bench`,
/// so that keys sort in the order of their numbers.
const key_number_size = @sizeOf(u64);

/// The most threads `--threads` accepts.
const threads_max = 64;

/// The most operations `--histogram=1` will set aside room to time: eight
/// bytes each, so 2 GiB.
const samples_max = 256 * 1024 * 1024;

const Benchmark = enum {
    /// Writes every key once, in key order, into an empty store.
    fillseq,
    /// Writes `writes` keys picked at random, into an empty store.
    fillrandom,
    /// Writes `writes` keys picked at random, into the store as it is.
    overwrite,
    /// Looks up `reads` keys picked at random. With `--threads` above 1,
    /// every thread looks up `reads` keys.
    readrandom,
    /// The same, but every key is one the workloads never write: a written
    /// key with one more byte on the end, as in `db_bench`. Such a key sorts
    /// between two written keys, so only looking in the tables can rule it
    /// out.
    readmissing,
    /// The lookups of `readrandom` from `--threads` threads, while one
    /// more thread writes keys picked at random, one at a time, until they
    /// finish.
    readwhilewriting,
    /// Reads `reads` entries in key order from the start of the store.
    readseq,
    /// Seeks to `reads` keys picked at random, and reads `seek_nexts`
    /// entries from each, or one entry if `seek_nexts` is 0.
    seekrandom,
    /// Writes everything the memtables hold to tables, so that every entry
    /// is in a table and the logs are empty.
    flush,
    /// Prints how many tables the store has, and their size.
    levelstats,
};

const Config = struct {
    benchmarks: []const u8 = "fillseq,readrandom,readseq",
    num: u64 = 100_000,
    /// `null` means the same as `num`.
    reads: ?u64 = null,
    key_size: usize = 16,
    value_size: usize = 100,
    batch_size: u64 = 1,
    /// `null` means the same as `num`.
    writes: ?u64 = null,
    threads: u64 = 1,
    seek_nexts: u64 = 0,
    seed: u64 = 0,
    db: []const u8 = ".zig-cache/bean-bench",
    use_existing_db: bool = false,
    histogram: bool = false,
    /// Seconds after which a workload of random reads or writes stops.
    /// 0 means no limit.
    duration: u64 = 0,

    fn readCount(config: Config) u64 {
        if (config.reads) |reads| {
            return reads;
        }
        return config.num;
    }

    fn writeCount(config: Config) u64 {
        if (config.writes) |writes| {
            return writes;
        }
        return config.num;
    }
};

/// How the times of a workload's operations were spread.
const LatencySummary = struct {
    /// What was timed: "write", "read" or "seek", as `db_bench` names them.
    operation: []const u8,
    count: u64,
    average_ns: f64,
    min_ns: u64,
    max_ns: u64,
    p50_ns: u64,
    p75_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    p9999_ns: u64,
};

/// Returns the smallest time in `sorted_ns` that at least
/// `per_ten_thousand` in every 10,000 of the times are no longer than.
fn percentile(sorted_ns: []const u64, per_ten_thousand: u64) u64 {
    assert(sorted_ns.len > 0);
    assert(per_ten_thousand <= 10_000);
    const count: u64 = sorted_ns.len;
    var rank = (count * per_ten_thousand + 9_999) / 10_000;
    if (rank == 0) {
        rank = 1;
    }
    return sorted_ns[@intCast(rank - 1)];
}

/// Sorts `samples_ns` and summarizes them. Returns `null` if there are none.
fn summarizeLatencies(operation: []const u8, samples_ns: []u64) ?LatencySummary {
    if (samples_ns.len == 0) {
        return null;
    }
    std.mem.sort(u64, samples_ns, {}, std.sort.asc(u64));

    var total_ns: f64 = 0;
    for (samples_ns) |sample_ns| {
        total_ns += @floatFromInt(sample_ns);
    }
    const count: f64 = @floatFromInt(samples_ns.len);

    return .{
        .operation = operation,
        .count = samples_ns.len,
        .average_ns = total_ns / count,
        .min_ns = samples_ns[0],
        .max_ns = samples_ns[samples_ns.len - 1],
        .p50_ns = percentile(samples_ns, 5_000),
        .p75_ns = percentile(samples_ns, 7_500),
        .p99_ns = percentile(samples_ns, 9_900),
        .p999_ns = percentile(samples_ns, 9_990),
        .p9999_ns = percentile(samples_ns, 9_999),
    };
}

/// When a workload must stop, if it was given a time limit.
const Deadline = struct {
    io: Io,
    /// A reading of `nowNs`. 0 when there is no limit.
    end_ns: u64,

    /// Starts the time now. `seconds` of 0 means no limit.
    fn start(io: Io, seconds: u64) Deadline {
        if (seconds == 0) {
            return .{ .io = io, .end_ns = 0 };
        }
        return .{ .io = io, .end_ns = nowNs(io) + seconds * std.time.ns_per_s };
    }

    fn passed(deadline: Deadline) bool {
        if (deadline.end_ns == 0) {
            return false;
        }
        return nowNs(deadline.io) >= deadline.end_ns;
    }
};

/// Times one thread's operations, one at a time, when `--histogram=1`.
/// Without it, `samples_ns` is empty and the timer does nothing.
const OperationTimer = struct {
    io: Io,
    /// One place for each operation the thread may time.
    samples_ns: []u64,
    /// How many operations have been timed.
    count: usize,
    /// When the operation being timed began.
    start_ns: u64,

    fn init(io: Io, samples_ns: []u64) OperationTimer {
        return .{ .io = io, .samples_ns = samples_ns, .count = 0, .start_ns = 0 };
    }

    /// Call just before an operation.
    fn begin(timer: *OperationTimer) void {
        if (timer.samples_ns.len == 0) {
            return;
        }
        timer.start_ns = nowNs(timer.io);
    }

    /// Call just after the operation `begin` was called for. An operation
    /// that failed is not timed: leave this call out.
    fn end(timer: *OperationTimer) void {
        if (timer.samples_ns.len == 0) {
            return;
        }
        assert(timer.count < timer.samples_ns.len);
        timer.samples_ns[timer.count] = nowNs(timer.io) - timer.start_ns;
        timer.count += 1;
    }
};

/// Returns thread `thread_number`'s part of `samples_ns`, which holds
/// `per_thread` places for each thread, or nothing if `samples_ns` is empty.
fn threadSamples(samples_ns: []u64, thread_number: usize, per_thread: usize) []u64 {
    if (samples_ns.len == 0) {
        return samples_ns;
    }
    return samples_ns[thread_number * per_thread ..][0..per_thread];
}

/// Moves the times `timer` recorded to `samples_ns[gathered..]`, and returns
/// how many times `samples_ns` then holds at its start. `timer` must have
/// recorded into a part of `samples_ns` that starts at or after `gathered`,
/// which holds when the threads' timers are gathered in thread order.
fn gatherSamples(samples_ns: []u64, gathered: usize, timer: OperationTimer) usize {
    const recorded = timer.samples_ns[0..timer.count];
    std.mem.copyForwards(u64, samples_ns[gathered..][0..recorded.len], recorded);
    return gathered + recorded.len;
}

/// What one workload did.
const Result = struct {
    operations: u64,
    /// Bytes of keys and values written or read.
    bytes: u64,
    elapsed_ns: u64,
    /// For lookups, how many keys were found. `null` for other workloads.
    found: ?u64 = null,
    /// Whether the store filled up before the workload finished.
    store_full: bool = false,
    /// How many threads did the operations.
    threads: u64 = 1,
    /// For writes, how many batches the operations went to the store in.
    /// Each batch is one sync. `null` for other workloads.
    groups: ?u64 = null,
    /// For `readwhilewriting`, how many writes the writer thread made.
    /// `null` for other workloads.
    writes_meanwhile: ?u64 = null,
    /// With `--histogram=1`, how the times of the operations were spread.
    /// With several threads these are the times of all of them together.
    latency: ?LatencySummary = null,
};

const ArgumentError = error{InvalidArgument};

fn parseNumber(name: []const u8, text: []const u8) ArgumentError!u64 {
    return std.fmt.parseInt(u64, text, 10) catch {
        std.debug.print("bean-bench: --{s} needs a number, got '{s}'\n", .{ name, text });
        return error.InvalidArgument;
    };
}

/// Reads one `--name=value` argument into `config`.
fn parseArgument(config: *Config, argument: []const u8) ArgumentError!void {
    const prefix = "--";
    const equals = std.mem.indexOfScalar(u8, argument, '=');
    if (!std.mem.startsWith(u8, argument, prefix) or equals == null) {
        std.debug.print("bean-bench: expected --name=value, got '{s}'\n", .{argument});
        return error.InvalidArgument;
    }
    const name = argument[prefix.len..equals.?];
    const value = argument[equals.? + 1 ..];

    if (std.mem.eql(u8, name, "benchmarks")) {
        config.benchmarks = value;
    } else if (std.mem.eql(u8, name, "num")) {
        config.num = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "reads")) {
        config.reads = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "key_size")) {
        config.key_size = @intCast(try parseNumber(name, value));
    } else if (std.mem.eql(u8, name, "value_size")) {
        config.value_size = @intCast(try parseNumber(name, value));
    } else if (std.mem.eql(u8, name, "batch_size")) {
        config.batch_size = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "writes")) {
        config.writes = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "threads")) {
        config.threads = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "seek_nexts")) {
        config.seek_nexts = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "seed")) {
        config.seed = try parseNumber(name, value);
    } else if (std.mem.eql(u8, name, "db")) {
        config.db = value;
    } else if (std.mem.eql(u8, name, "use_existing_db")) {
        config.use_existing_db = (try parseNumber(name, value)) != 0;
    } else if (std.mem.eql(u8, name, "histogram")) {
        config.histogram = (try parseNumber(name, value)) != 0;
    } else if (std.mem.eql(u8, name, "duration")) {
        config.duration = try parseNumber(name, value);
    } else {
        std.debug.print("bean-bench: unknown flag --{s}\n", .{name});
        return error.InvalidArgument;
    }
}

/// Checks the sizes in `config` against what the store accepts.
fn checkConfig(config: Config) ArgumentError!void {
    if (config.key_size < key_number_size or config.key_size > key_size_max) {
        std.debug.print("bean-bench: --key_size must be between {d} and {d}\n", .{ key_number_size, key_size_max });
        return error.InvalidArgument;
    }
    if (config.value_size > value_size_max) {
        std.debug.print("bean-bench: --value_size must be at most {d}\n", .{value_size_max});
        return error.InvalidArgument;
    }
    if (config.num == 0 or config.batch_size == 0) {
        std.debug.print("bean-bench: --num and --batch_size must be at least 1\n", .{});
        return error.InvalidArgument;
    }
    if (config.writes != null and config.writes.? == 0) {
        std.debug.print("bean-bench: --writes must be at least 1\n", .{});
        return error.InvalidArgument;
    }
    if (config.histogram) {
        // Room is set aside to time every operation a workload may do.
        var operations_max = config.readCount();
        if (config.writeCount() > operations_max) {
            operations_max = config.writeCount();
        }
        const samples = std.math.mul(u64, operations_max, config.threads) catch samples_max + 1;
        if (samples > samples_max) {
            std.debug.print("bean-bench: with --histogram=1, --reads and --writes times --threads must be at most {d}\n", .{samples_max});
            return error.InvalidArgument;
        }
    }
    // `readmissing` looks up keys one byte longer than `--key_size`.
    const reads_missing = std.mem.indexOf(u8, config.benchmarks, "readmissing") != null;
    if (reads_missing and config.key_size == key_size_max) {
        std.debug.print("bean-bench: with readmissing, --key_size must be below {d}\n", .{key_size_max});
        return error.InvalidArgument;
    }

    if (config.threads == 0 or config.threads > threads_max) {
        std.debug.print("bean-bench: --threads must be between 1 and {d}\n", .{threads_max});
        return error.InvalidArgument;
    }
    if (config.threads > 1 and config.batch_size != 1) {
        std.debug.print("bean-bench: with --threads above 1, --batch_size must be 1\n", .{});
        return error.InvalidArgument;
    }

    // A whole batch must fit in the write batch's buffer.
    const operation_size = write_batch.operation_size_min + config.key_size + config.value_size;
    const batch_size_max = write_batch.size_max / operation_size;
    if (config.batch_size > batch_size_max) {
        std.debug.print("bean-bench: --batch_size must be at most {d} for these key and value sizes\n", .{batch_size_max});
        return error.InvalidArgument;
    }
}

/// A reading of a clock that only moves forwards, in nanoseconds.
fn nowNs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

/// Everything the workloads share.
const Bench = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: Config,
    dir: Io.Dir,
    store: kv.Store,
    batch: WriteBatch,
    prng: std.Random.DefaultPrng,
    key_buffer: [key_size_max]u8,
    /// The value every put writes: `value_size` bytes of noise.
    value: []u8,
    /// Holds each value the single-threaded lookups read. Long enough for
    /// any value the store can hold, because the store in `--db` may have
    /// been written with a larger `--value_size` than this run's.
    read_buffer: []u8,
    /// The memory the scans work in.
    scan_buffers: kv.Store.IteratorBuffers,

    fn open(io: Io, gpa: std.mem.Allocator, config: Config) !Bench {
        var dir = try Io.Dir.cwd().createDirPathOpen(io, config.db, .{});
        errdefer dir.close(io);
        var store: kv.Store = try .open(gpa, io, dir, .{});
        errdefer store.close(gpa);
        var batch: WriteBatch = try .init(gpa);
        errdefer batch.deinit(gpa);

        const value = try gpa.alloc(u8, config.value_size);
        errdefer gpa.free(value);
        var value_prng: std.Random.DefaultPrng = .init(config.seed);
        value_prng.random().bytes(value);

        const read_buffer = try gpa.alloc(u8, value_size_max);
        errdefer gpa.free(read_buffer);
        const scan_buffers: kv.Store.IteratorBuffers = try .init(gpa);

        return .{
            .io = io,
            .gpa = gpa,
            .config = config,
            .dir = dir,
            .store = store,
            .batch = batch,
            .prng = .init(config.seed),
            .key_buffer = undefined,
            .value = value,
            .read_buffer = read_buffer,
            .scan_buffers = scan_buffers,
        };
    }

    fn close(self: *Bench) void {
        self.store.close(self.gpa);
        self.batch.deinit(self.gpa);
        self.dir.close(self.io);
        self.gpa.free(self.value);
        self.gpa.free(self.read_buffer);
        self.scan_buffers.deinit(self.gpa);
    }

    /// Replaces the store with a new, empty one in the same directory. If
    /// this fails the program cannot carry on, so it exits.
    fn startFromEmpty(self: *Bench) void {
        self.store.close(self.gpa);
        self.dir.close(self.io);

        self.openEmpty() catch |err| {
            std.debug.print("bean-bench: could not start a new store in {s}: {t}\n", .{ self.config.db, err });
            std.process.exit(1);
        };
    }

    /// Removes the store's directory and opens a new store in it. The store
    /// and directory must already be closed.
    fn openEmpty(self: *Bench) !void {
        try Io.Dir.cwd().deleteTree(self.io, self.config.db);
        self.dir = try Io.Dir.cwd().createDirPathOpen(self.io, self.config.db, .{});
        errdefer self.dir.close(self.io);
        self.store = try .open(self.gpa, self.io, self.dir, .{});
    }

    /// Returns key number `key_number`: the number as eight big-endian
    /// bytes, then '0' up to the key size. Valid until the next call.
    fn makeKey(self: *Bench, key_number: u64) []const u8 {
        return self.makeKeyOfSize(key_number, self.config.key_size);
    }

    /// The same, for a key of `key_size` bytes.
    fn makeKeyOfSize(self: *Bench, key_number: u64, key_size: usize) []const u8 {
        const key = self.key_buffer[0..key_size];
        std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
        @memset(key[key_number_size..], '0');
        return key;
    }

    /// Which keys a lookup workload asks for.
    const KeyChoice = enum {
        /// Keys the write workloads write.
        written,
        /// Keys they never write: one byte longer than a written key.
        missing,
    };

    /// The size of the keys a lookup workload asks for.
    fn lookupKeySize(self: *const Bench, key_choice: KeyChoice) usize {
        switch (key_choice) {
            .written => return self.config.key_size,
            .missing => return self.config.key_size + 1,
        }
    }

    /// Returns room for each of `thread_count` threads to time `per_thread`
    /// operations, or nothing without `--histogram=1`. The caller frees it.
    fn allocSamples(self: *Bench, thread_count: usize, per_thread: usize) ![]u64 {
        if (!self.config.histogram) {
            return &.{};
        }
        return self.gpa.alloc(u64, thread_count * per_thread);
    }

    fn randomKeyNumber(self: *Bench) u64 {
        return self.prng.random().uintLessThan(u64, self.config.num);
    }

    /// Runs one workload. Returns `null` for a workload that prints what
    /// it has to say itself.
    fn run(self: *Bench, benchmark: Benchmark) !?Result {
        switch (benchmark) {
            .fillseq => {
                if (!self.config.use_existing_db) {
                    self.startFromEmpty();
                }
                return try self.writeKeys(.sequential);
            },
            .fillrandom => {
                if (!self.config.use_existing_db) {
                    self.startFromEmpty();
                }
                return try self.writeKeys(.random);
            },
            .overwrite => return try self.writeKeys(.random),
            .readrandom => {
                if (self.config.threads > 1) {
                    return try self.readFromThreads(.written, .no_writer);
                }
                return try self.readRandom(.written);
            },
            .readmissing => {
                if (self.config.threads > 1) {
                    return try self.readFromThreads(.missing, .no_writer);
                }
                return try self.readRandom(.missing);
            },
            .readwhilewriting => return try self.readFromThreads(.written, .with_writer),
            .readseq => return try self.readSequential(),
            .seekrandom => return try self.seekRandom(),
            .flush => return try self.flushStore(),
            .levelstats => {
                self.printTables();
                return null;
            },
        }
    }

    /// Writes the memtables to tables. One operation, however much it wrote.
    fn flushStore(self: *Bench) !Result {
        var result: Result = .{ .operations = 1, .bytes = 0, .elapsed_ns = 0 };

        const start_ns = nowNs(self.io);
        self.store.flush() catch |err| switch (err) {
            error.StoreFull => {
                result.store_full = true;
            },
            else => |other| return other,
        };
        result.elapsed_ns = nowNs(self.io) - start_ns;
        return result;
    }

    /// Prints how many tables the store has and how large they are together.
    /// Entries still in a memtable are in no table.
    fn printTables(self: *Bench) void {
        var table_count: u64 = 0;
        var table_bytes: u64 = 0;
        for (self.store.tables.slots) |slot| {
            if (slot.in_use) {
                table_count += 1;
                table_bytes += slot.table.file_size;
            }
        }
        const megabytes = @as(f64, @floatFromInt(table_bytes)) / (1024 * 1024);
        std.debug.print("Tables: {d} of at most {d}, {d:.1} MB\n", .{ table_count, kv.tables_max, megabytes });
    }

    const KeyOrder = enum { sequential, random };

    /// The time limit for a write workload, in seconds. As in `db_bench`,
    /// `--duration` limits only writes of keys picked at random.
    fn writeDuration(config: Config, order: KeyOrder) u64 {
        switch (order) {
            .sequential => return 0,
            .random => return config.duration,
        }
    }

    /// Writes keys with one thread or with several, as `--threads` says.
    fn writeKeys(self: *Bench, order: KeyOrder) !Result {
        if (self.config.threads > 1) {
            return self.writeKeysFromThreads(order);
        }
        return self.writeKeysInBatches(order);
    }

    /// What one writer thread is given, and what it reports back.
    const WriterThread = struct {
        bench: *Bench,
        committer: *GroupCommitter,
        order: KeyOrder,
        thread_number: u64,
        /// Times each write, from the call to its being durable.
        timer: OperationTimer,
        /// How many keys the thread wrote.
        operations: u64,
        /// Whether the thread stopped because the store was full.
        store_full: bool,
        /// Any other error that stopped the thread.
        failure: ?GroupCommitter.Error,

        /// Writes `writes` keys, one at a time, each durable before the
        /// next. Stops early at the time limit, if there is one.
        fn run(writer: *WriterThread) void {
            const config = writer.bench.config;
            var prng: std.Random.DefaultPrng = .init(config.seed + writer.thread_number);
            var key_buffer: [key_size_max]u8 = undefined;
            const key = key_buffer[0..config.key_size];
            const deadline: Deadline = .start(writer.bench.io, writeDuration(config, writer.order));

            while (writer.operations < config.writeCount() and !deadline.passed()) {
                var key_number = writer.operations;
                if (writer.order == .random) {
                    key_number = prng.random().uintLessThan(u64, config.num);
                }
                std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
                @memset(key[key_number_size..], '0');

                writer.timer.begin();
                writer.committer.put(key, writer.bench.value) catch |err| switch (err) {
                    error.StoreFull => {
                        writer.store_full = true;
                        return;
                    },
                    else => {
                        writer.failure = err;
                        return;
                    },
                };
                writer.timer.end();
                writer.operations += 1;
            }
        }
    };

    /// Starts `threads` threads that each write `writes` keys one at a time
    /// through a group committer, as `db_bench` does with its threads.
    fn writeKeysFromThreads(self: *Bench, order: KeyOrder) !Result {
        const operation_bytes = self.config.key_size + self.config.value_size;
        const thread_count: usize = @intCast(self.config.threads);

        var committer: GroupCommitter = try .init(self.gpa, self.io, &self.store);
        defer committer.deinit(self.gpa);

        const writes_per_thread: usize = @intCast(self.config.writeCount());
        const samples_ns = try self.allocSamples(thread_count, writes_per_thread);
        defer self.gpa.free(samples_ns);

        var writers: [threads_max]WriterThread = undefined;
        var threads: [threads_max]std.Thread = undefined;
        for (writers[0..thread_count], 0..) |*writer, thread_number| {
            writer.* = .{
                .bench = self,
                .committer = &committer,
                .order = order,
                .thread_number = thread_number,
                .timer = .init(self.io, threadSamples(samples_ns, thread_number, writes_per_thread)),
                .operations = 0,
                .store_full = false,
                .failure = null,
            };
        }

        const start_ns = nowNs(self.io);
        var started: usize = 0;
        while (started < thread_count) {
            threads[started] = try std.Thread.spawn(.{}, WriterThread.run, .{&writers[started]});
            started += 1;
        }
        for (threads[0..thread_count]) |thread| {
            thread.join();
        }
        const elapsed_ns = nowNs(self.io) - start_ns;

        var result: Result = .{
            .operations = 0,
            .bytes = 0,
            .elapsed_ns = elapsed_ns,
            .threads = self.config.threads,
            .groups = committer.groupsWritten(),
        };
        var gathered: usize = 0;
        for (writers[0..thread_count]) |writer| {
            if (writer.failure) |err| {
                return err;
            }
            if (writer.store_full) {
                result.store_full = true;
            }
            result.operations += writer.operations;
            result.bytes += writer.operations * operation_bytes;
            gathered = gatherSamples(samples_ns, gathered, writer.timer);
        }
        result.latency = summarizeLatencies("write", samples_ns[0..gathered]);
        return result;
    }

    /// Writes `writes` keys in batches of `batch_size`, and stops early if
    /// the store fills up or at the time limit. With `--histogram=1` each
    /// batch is timed, not each key, as in `db_bench`.
    fn writeKeysInBatches(self: *Bench, order: KeyOrder) !Result {
        const operation_bytes = self.config.key_size + self.config.value_size;
        const write_count = self.config.writeCount();
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0 };

        const batch_count: usize = @intCast(std.math.divCeil(u64, write_count, self.config.batch_size) catch unreachable);
        const samples_ns = try self.allocSamples(1, batch_count);
        defer self.gpa.free(samples_ns);
        var timer: OperationTimer = .init(self.io, samples_ns);
        const deadline: Deadline = .start(self.io, writeDuration(self.config, order));
        var batches_written: u64 = 0;

        const start_ns = nowNs(self.io);
        while (result.operations < write_count and !deadline.passed()) {
            const operations_left = write_count - result.operations;
            const batch_operations = @min(self.config.batch_size, operations_left);

            self.batch.clear();
            var added: u64 = 0;
            while (added < batch_operations) {
                var key_number = result.operations + added;
                if (order == .random) {
                    key_number = self.randomKeyNumber();
                }
                // `checkConfig` made sure a whole batch fits.
                try self.batch.put(self.makeKey(key_number), self.value);
                added += 1;
            }

            timer.begin();
            self.store.write(&self.batch) catch |err| switch (err) {
                error.StoreFull => {
                    result.store_full = true;
                    break;
                },
                // Anything else ends the run. That includes `StoreBroken`,
                // and `EmptyBatch`, which `checkConfig` rules out by making
                // every batch hold at least one operation.
                else => |other| return other,
            };
            timer.end();
            batches_written += 1;
            result.operations += batch_operations;
            result.bytes += batch_operations * operation_bytes;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        result.groups = batches_written;
        result.latency = summarizeLatencies("write", samples_ns[0..timer.count]);
        return result;
    }

    fn readRandom(self: *Bench, key_choice: KeyChoice) !Result {
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0, .found = 0 };
        const key_size = self.lookupKeySize(key_choice);

        const read_count: usize = @intCast(self.config.readCount());
        const samples_ns = try self.allocSamples(1, read_count);
        defer self.gpa.free(samples_ns);
        var timer: OperationTimer = .init(self.io, samples_ns);
        const deadline: Deadline = .start(self.io, self.config.duration);

        const start_ns = nowNs(self.io);
        while (result.operations < self.config.readCount() and !deadline.passed()) {
            const key = self.makeKeyOfSize(self.randomKeyNumber(), key_size);
            timer.begin();
            const value = try self.store.get(key, self.read_buffer);
            timer.end();
            if (value != null) {
                result.found.? += 1;
                result.bytes += key.len + value.?.len;
            }
            result.operations += 1;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        result.latency = summarizeLatencies("read", samples_ns[0..timer.count]);
        return result;
    }

    /// What one reader thread is given, and what it reports back.
    const ReaderThread = struct {
        bench: *Bench,
        committer: *GroupCommitter,
        thread_number: u64,
        /// The size of the keys to look up.
        key_size: usize,
        /// Times each lookup, the wait for its turn included.
        timer: OperationTimer,
        /// Holds each value read. As long as the values the benchmark
        /// writes.
        value_buffer: []u8,
        operations: u64,
        found: u64,
        bytes: u64,
        /// An error that stopped the thread.
        failure: ?GroupCommitter.GetError,

        /// Looks up `reads` keys picked at random. Stops early at the time
        /// limit, if there is one.
        fn run(reader: *ReaderThread) void {
            const config = reader.bench.config;
            var prng: std.Random.DefaultPrng = .init(config.seed + reader.thread_number);
            var key_buffer: [key_size_max]u8 = undefined;
            const key = key_buffer[0..reader.key_size];
            const deadline: Deadline = .start(reader.bench.io, config.duration);

            while (reader.operations < config.readCount() and !deadline.passed()) {
                const key_number = prng.random().uintLessThan(u64, config.num);
                std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
                @memset(key[key_number_size..], '0');

                reader.timer.begin();
                const value = reader.committer.get(key, reader.value_buffer) catch |err| {
                    reader.failure = err;
                    return;
                };
                reader.timer.end();
                if (value != null) {
                    reader.found += 1;
                    reader.bytes += key.len + value.?.len;
                }
                reader.operations += 1;
            }
        }
    };

    /// The thread that writes during `readwhilewriting`.
    const BackgroundWriter = struct {
        bench: *Bench,
        committer: *GroupCommitter,
        /// Set by the main thread once the readers have finished.
        stop: std.atomic.Value(bool),
        /// How many keys the thread wrote.
        operations: u64,

        /// Writes keys picked at random, one at a time, until told to stop.
        /// It also stops if a write fails, for example when the store is
        /// full; the readers carry on without it.
        fn run(writer: *BackgroundWriter) void {
            const config = writer.bench.config;
            var prng: std.Random.DefaultPrng = .init(config.seed + threads_max);
            var key_buffer: [key_size_max]u8 = undefined;
            const key = key_buffer[0..config.key_size];

            while (!writer.stop.load(.monotonic)) {
                const key_number = prng.random().uintLessThan(u64, config.num);
                std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
                @memset(key[key_number_size..], '0');

                writer.committer.put(key, writer.bench.value) catch {
                    return;
                };
                writer.operations += 1;
            }
        }
    };

    const WriterChoice = enum { no_writer, with_writer };

    /// Starts `threads` threads that each look up `reads` keys through a
    /// group committer. With `.with_writer`, one more thread writes until
    /// they have finished.
    fn readFromThreads(self: *Bench, key_choice: KeyChoice, writer_choice: WriterChoice) !Result {
        const thread_count: usize = @intCast(self.config.threads);
        const key_size = self.lookupKeySize(key_choice);

        const reads_per_thread: usize = @intCast(self.config.readCount());
        const samples_ns = try self.allocSamples(thread_count, reads_per_thread);
        defer self.gpa.free(samples_ns);

        var committer: GroupCommitter = try .init(self.gpa, self.io, &self.store);
        defer committer.deinit(self.gpa);

        const value_buffers = try self.gpa.alloc(u8, thread_count * self.config.value_size);
        defer self.gpa.free(value_buffers);

        var readers: [threads_max]ReaderThread = undefined;
        var reader_threads: [threads_max]std.Thread = undefined;
        for (readers[0..thread_count], 0..) |*reader, thread_number| {
            const buffer_start = thread_number * self.config.value_size;
            reader.* = .{
                .bench = self,
                .committer = &committer,
                .thread_number = thread_number,
                .key_size = key_size,
                .timer = .init(self.io, threadSamples(samples_ns, thread_number, reads_per_thread)),
                .value_buffer = value_buffers[buffer_start..][0..self.config.value_size],
                .operations = 0,
                .found = 0,
                .bytes = 0,
                .failure = null,
            };
        }
        var writer: BackgroundWriter = .{
            .bench = self,
            .committer = &committer,
            .stop = .init(false),
            .operations = 0,
        };

        const start_ns = nowNs(self.io);
        var writer_thread: ?std.Thread = null;
        if (writer_choice == .with_writer) {
            writer_thread = try std.Thread.spawn(.{}, BackgroundWriter.run, .{&writer});
        }
        var started: usize = 0;
        while (started < thread_count) {
            reader_threads[started] = try std.Thread.spawn(.{}, ReaderThread.run, .{&readers[started]});
            started += 1;
        }
        for (reader_threads[0..thread_count]) |thread| {
            thread.join();
        }
        const elapsed_ns = nowNs(self.io) - start_ns;

        writer.stop.store(true, .monotonic);
        if (writer_thread) |thread| {
            thread.join();
        }

        var result: Result = .{
            .operations = 0,
            .bytes = 0,
            .elapsed_ns = elapsed_ns,
            .found = 0,
            .threads = self.config.threads,
        };
        if (writer_choice == .with_writer) {
            result.writes_meanwhile = writer.operations;
        }
        var gathered: usize = 0;
        for (readers[0..thread_count]) |reader| {
            if (reader.failure) |err| {
                return err;
            }
            result.operations += reader.operations;
            result.found.? += reader.found;
            result.bytes += reader.bytes;
            gathered = gatherSamples(samples_ns, gathered, reader.timer);
        }
        result.latency = summarizeLatencies("read", samples_ns[0..gathered]);
        return result;
    }

    fn readSequential(self: *Bench) !Result {
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0 };

        const start_ns = nowNs(self.io);
        var entries = self.store.iterator(&self.scan_buffers);
        while (result.operations < self.config.readCount()) {
            const entry = try entries.next();
            if (entry == null) {
                break;
            }
            result.bytes += entry.?.key.len + entry.?.value.len;
            result.operations += 1;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        return result;
    }

    /// Seeks to keys picked at random and reads on from each. A seek counts
    /// as found when it lands on the very key it asked for, as in
    /// `db_bench`, not when it lands on any entry.
    fn seekRandom(self: *Bench) !Result {
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0, .found = 0 };

        // `db_bench` moves its cursor on `seek_nexts` times after a seek.
        // Reading an entry here moves the cursor on once, so this reads
        // `seek_nexts` entries. It reads one even when `seek_nexts` is 0,
        // because the only way to see where a seek landed is to read.
        var entries_wanted = self.config.seek_nexts;
        if (entries_wanted == 0) {
            entries_wanted = 1;
        }

        const read_count: usize = @intCast(self.config.readCount());
        const samples_ns = try self.allocSamples(1, read_count);
        defer self.gpa.free(samples_ns);
        var timer: OperationTimer = .init(self.io, samples_ns);
        const deadline: Deadline = .start(self.io, self.config.duration);

        const start_ns = nowNs(self.io);
        while (result.operations < self.config.readCount() and !deadline.passed()) {
            const target = self.makeKey(self.randomKeyNumber());
            var landed_on_target = false;

            // A new cursor for every seek, as in `db_bench`.
            timer.begin();
            var entries = self.store.iterator(&self.scan_buffers);
            try entries.seek(target);
            var entries_read: u64 = 0;
            while (entries_read < entries_wanted) {
                const entry = try entries.next();
                if (entry == null) {
                    break;
                }
                if (entries_read == 0 and std.mem.eql(u8, entry.?.key, target)) {
                    landed_on_target = true;
                }
                result.bytes += entry.?.key.len + entry.?.value.len;
                entries_read += 1;
            }
            timer.end();

            if (landed_on_target) {
                result.found.? += 1;
            }
            result.operations += 1;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        result.latency = summarizeLatencies("seek", samples_ns[0..timer.count]);
        return result;
    }
};

/// Prints one result in the layout `db_bench` uses.
fn printResult(name: []const u8, result: Result) void {
    const seconds = @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_s;
    const operations: f64 = @floatFromInt(result.operations);
    const megabytes = @as(f64, @floatFromInt(result.bytes)) / (1024 * 1024);

    var micros_per_operation: f64 = 0;
    var operations_per_second: f64 = 0;
    var megabytes_per_second: f64 = 0;
    if (result.operations > 0 and seconds > 0) {
        // As in `db_bench`, the time per operation is what each thread saw:
        // with several threads, every one of them waited the whole time.
        const threads: f64 = @floatFromInt(result.threads);
        micros_per_operation = threads * seconds * std.time.us_per_s / operations;
        operations_per_second = operations / seconds;
        megabytes_per_second = megabytes / seconds;
    }

    std.debug.print("{s:<12} : {d:>11.3} micros/op {d:.0} ops/sec {d:.3} seconds {d} operations; {d:>6.1} MB/s", .{
        name,
        micros_per_operation,
        operations_per_second,
        seconds,
        result.operations,
        megabytes_per_second,
    });
    if (result.found) |found| {
        std.debug.print(" ({d} of {d} found)", .{ found, result.operations });
    }
    if (result.groups) |groups| {
        var operations_per_group: f64 = 0;
        if (groups > 0) {
            operations_per_group = operations / @as(f64, @floatFromInt(groups));
        }
        std.debug.print(" ({d} syncs, {d:.1} operations each)", .{ groups, operations_per_group });
    }
    if (result.writes_meanwhile) |writes| {
        std.debug.print(" ({d} writes meanwhile)", .{writes});
    }
    if (result.store_full) {
        std.debug.print(" (stopped: the store is full)", .{});
    }
    std.debug.print("\n", .{});

    if (result.latency) |latency| {
        printLatency(latency);
    }
}

fn microseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

/// Prints the spread of the times in the layout `db_bench --histogram=1`
/// uses, without its standard deviation and its table of buckets.
fn printLatency(latency: LatencySummary) void {
    std.debug.print("Microseconds per {s}:\n", .{latency.operation});
    std.debug.print("Count: {d} Average: {d:.4}\n", .{
        latency.count,
        latency.average_ns / std.time.ns_per_us,
    });
    std.debug.print("Min: {d:.2} Median: {d:.2} Max: {d:.2}\n", .{
        microseconds(latency.min_ns),
        microseconds(latency.p50_ns),
        microseconds(latency.max_ns),
    });
    std.debug.print("Percentiles: P50: {d:.2} P75: {d:.2} P99: {d:.2} P99.9: {d:.2} P99.99: {d:.2}\n", .{
        microseconds(latency.p50_ns),
        microseconds(latency.p75_ns),
        microseconds(latency.p99_ns),
        microseconds(latency.p999_ns),
        microseconds(latency.p9999_ns),
    });
}

pub fn main(init: std.process.Init) !void {
    var config: Config = .{};
    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();
    while (arguments.next()) |argument| {
        parseArgument(&config, argument) catch std.process.exit(1);
    }
    checkConfig(config) catch std.process.exit(1);

    std.debug.print("bean-bench\n", .{});
    std.debug.print("Keys:       {d} bytes each\n", .{config.key_size});
    std.debug.print("Values:     {d} bytes each\n", .{config.value_size});
    std.debug.print("Entries:    {d}\n", .{config.num});
    std.debug.print("Writes:     {d} for each thread\n", .{config.writeCount()});
    std.debug.print("Batch size: {d}\n", .{config.batch_size});
    std.debug.print("Threads:    {d}\n", .{config.threads});
    std.debug.print("Sync:       every write batch\n", .{});
    std.debug.print("------------------------------------------------\n", .{});

    var bench: Bench = try .open(init.io, std.heap.page_allocator, config);
    defer bench.close();

    var names = std.mem.splitScalar(u8, config.benchmarks, ',');
    while (names.next()) |name| {
        const benchmark = std.meta.stringToEnum(Benchmark, name);
        if (benchmark == null) {
            std.debug.print("bean-bench: unknown benchmark '{s}'\n", .{name});
            std.process.exit(1);
        }
        const result = try bench.run(benchmark.?);
        if (result != null) {
            printResult(name, result.?);
        }
    }
}
