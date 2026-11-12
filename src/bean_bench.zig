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
//!     --threads=N           threads that work at once. Each writes `num`
//!                           keys one at a time, or does `reads` lookups
//!     --seek_nexts=N        entries read after each seek in `seekrandom`
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
//! Two things differ from `db_bench`. Every write batch is synced to disk
//! before the write returns, because bean has no unsynced mode, which is
//! what `db_bench --sync=1` does. And a store holds only what fits in its
//! memtable until flushing is built, so a workload that fills it stops early
//! and says so.

const std = @import("std");
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

const Benchmark = enum {
    /// Writes every key once, in key order, into an empty store.
    fillseq,
    /// Writes `num` keys picked at random, into an empty store.
    fillrandom,
    /// Writes `num` keys picked at random, into the store as it is.
    overwrite,
    /// Looks up `reads` keys picked at random. With `--threads` above 1,
    /// every thread looks up `reads` keys.
    readrandom,
    /// The same lookups from `--threads` threads, while one more thread
    /// writes keys picked at random, one at a time, until they finish.
    readwhilewriting,
    /// Reads `reads` entries in key order from the start of the store.
    readseq,
    /// Seeks to `reads` keys picked at random, and reads `seek_nexts`
    /// entries after each.
    seekrandom,
};

const Config = struct {
    benchmarks: []const u8 = "fillseq,readrandom,readseq",
    num: u64 = 100_000,
    /// `null` means the same as `num`.
    reads: ?u64 = null,
    key_size: usize = 16,
    value_size: usize = 100,
    batch_size: u64 = 1,
    threads: u64 = 1,
    seek_nexts: u64 = 0,
    seed: u64 = 0,
    db: []const u8 = ".zig-cache/bean-bench",
    use_existing_db: bool = false,

    fn readCount(config: Config) u64 {
        if (config.reads) |reads| {
            return reads;
        }
        return config.num;
    }
};

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
    /// For writes made through a group committer, how many groups the
    /// operations went to the store in. `null` for other workloads.
    groups: ?u64 = null,
    /// For `readwhilewriting`, how many writes the writer thread made.
    /// `null` for other workloads.
    writes_meanwhile: ?u64 = null,
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
        const key = self.key_buffer[0..self.config.key_size];
        std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
        @memset(key[key_number_size..], '0');
        return key;
    }

    fn randomKeyNumber(self: *Bench) u64 {
        return self.prng.random().uintLessThan(u64, self.config.num);
    }

    fn run(self: *Bench, benchmark: Benchmark) !Result {
        switch (benchmark) {
            .fillseq => {
                if (!self.config.use_existing_db) {
                    self.startFromEmpty();
                }
                return self.writeKeys(.sequential);
            },
            .fillrandom => {
                if (!self.config.use_existing_db) {
                    self.startFromEmpty();
                }
                return self.writeKeys(.random);
            },
            .overwrite => return self.writeKeys(.random),
            .readrandom => {
                if (self.config.threads > 1) {
                    return self.readFromThreads(.no_writer);
                }
                return self.readRandom();
            },
            .readwhilewriting => return self.readFromThreads(.with_writer),
            .readseq => return self.readSequential(),
            .seekrandom => return self.seekRandom(),
        }
    }

    const KeyOrder = enum { sequential, random };

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
        /// How many keys the thread wrote.
        operations: u64,
        /// Whether the thread stopped because the store was full.
        store_full: bool,
        /// Any other error that stopped the thread.
        failure: ?GroupCommitter.Error,

        /// Writes `num` keys, one at a time, each durable before the next.
        fn run(writer: *WriterThread) void {
            const config = writer.bench.config;
            var prng: std.Random.DefaultPrng = .init(config.seed + writer.thread_number);
            var key_buffer: [key_size_max]u8 = undefined;
            const key = key_buffer[0..config.key_size];

            while (writer.operations < config.num) {
                var key_number = writer.operations;
                if (writer.order == .random) {
                    key_number = prng.random().uintLessThan(u64, config.num);
                }
                std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
                @memset(key[key_number_size..], '0');

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
                writer.operations += 1;
            }
        }
    };

    /// Starts `threads` threads that each write `num` keys one at a time
    /// through a group committer, as `db_bench` does with its threads.
    fn writeKeysFromThreads(self: *Bench, order: KeyOrder) !Result {
        const operation_bytes = self.config.key_size + self.config.value_size;
        const thread_count: usize = @intCast(self.config.threads);

        var committer: GroupCommitter = try .init(self.gpa, self.io, &self.store);
        defer committer.deinit(self.gpa);

        var writers: [threads_max]WriterThread = undefined;
        var threads: [threads_max]std.Thread = undefined;
        for (writers[0..thread_count], 0..) |*writer, thread_number| {
            writer.* = .{
                .bench = self,
                .committer = &committer,
                .order = order,
                .thread_number = thread_number,
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
        for (writers[0..thread_count]) |writer| {
            if (writer.failure) |err| {
                return err;
            }
            if (writer.store_full) {
                result.store_full = true;
            }
            result.operations += writer.operations;
            result.bytes += writer.operations * operation_bytes;
        }
        return result;
    }

    /// Writes `num` keys in batches of `batch_size`, and stops early if the
    /// store fills up.
    fn writeKeysInBatches(self: *Bench, order: KeyOrder) !Result {
        const operation_bytes = self.config.key_size + self.config.value_size;
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0 };

        const start_ns = nowNs(self.io);
        while (result.operations < self.config.num) {
            const operations_left = self.config.num - result.operations;
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
            result.operations += batch_operations;
            result.bytes += batch_operations * operation_bytes;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        return result;
    }

    fn readRandom(self: *Bench) !Result {
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0, .found = 0 };

        const start_ns = nowNs(self.io);
        while (result.operations < self.config.readCount()) {
            const key = self.makeKey(self.randomKeyNumber());
            const value = try self.store.get(key, self.read_buffer);
            if (value != null) {
                result.found.? += 1;
                result.bytes += key.len + value.?.len;
            }
            result.operations += 1;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
        return result;
    }

    /// What one reader thread is given, and what it reports back.
    const ReaderThread = struct {
        bench: *Bench,
        committer: *GroupCommitter,
        thread_number: u64,
        /// Holds each value read. As long as the values the benchmark
        /// writes.
        value_buffer: []u8,
        operations: u64,
        found: u64,
        bytes: u64,
        /// An error that stopped the thread.
        failure: ?GroupCommitter.GetError,

        /// Looks up `reads` keys picked at random.
        fn run(reader: *ReaderThread) void {
            const config = reader.bench.config;
            var prng: std.Random.DefaultPrng = .init(config.seed + reader.thread_number);
            var key_buffer: [key_size_max]u8 = undefined;
            const key = key_buffer[0..config.key_size];

            while (reader.operations < config.readCount()) {
                const key_number = prng.random().uintLessThan(u64, config.num);
                std.mem.writeInt(u64, key[0..key_number_size], key_number, .big);
                @memset(key[key_number_size..], '0');

                const value = reader.committer.get(key, reader.value_buffer) catch |err| {
                    reader.failure = err;
                    return;
                };
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
    fn readFromThreads(self: *Bench, writer_choice: WriterChoice) !Result {
        const thread_count: usize = @intCast(self.config.threads);

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
        for (readers[0..thread_count]) |reader| {
            if (reader.failure) |err| {
                return err;
            }
            result.operations += reader.operations;
            result.found.? += reader.found;
            result.bytes += reader.bytes;
        }
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

    fn seekRandom(self: *Bench) !Result {
        var result: Result = .{ .operations = 0, .bytes = 0, .elapsed_ns = 0, .found = 0 };

        const start_ns = nowNs(self.io);
        var entries = self.store.iterator(&self.scan_buffers);
        while (result.operations < self.config.readCount()) {
            try entries.seek(self.makeKey(self.randomKeyNumber()));

            // The entry the seek lands on, then `seek_nexts` more.
            var entries_read: u64 = 0;
            while (entries_read <= self.config.seek_nexts) {
                const entry = try entries.next();
                if (entry == null) {
                    break;
                }
                result.bytes += entry.?.key.len + entry.?.value.len;
                entries_read += 1;
            }
            if (entries_read > 0) {
                result.found.? += 1;
            }
            result.operations += 1;
        }
        result.elapsed_ns = nowNs(self.io) - start_ns;
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
        printResult(name, result);
    }
}
