#!/usr/bin/env bash
# Compares bean with RocksDB on the workloads a real system would put on
# them, with each store set up the way it runs best.
#
#     bench/compare-rocksdb.sh
#
# The rule: both stores give the same guarantee (a write is on disk before it
# is acknowledged), run on the same disk, and run under the same memory
# limit. Inside that, each is configured its own way. RocksDB gets bloom
# filters, a block cache that holds the data, and background threads. bean
# gets a group committer in front of it, which is how a single-threaded store
# takes writes from many clients.
#
# Two scenarios:
#
#   writes  Many clients each make single durable writes to a store that
#           already holds data. Run with 1, 4, 16 and 64 client threads.
#   reads   Lookups of keys that exist, lookups of keys that do not, and
#           short scans, on a store whose tables have settled. Then lookups
#           while one thread writes.
#
# Every measured step is a process of its own that runs for DURATION seconds,
# so its CPU time is the step's CPU time. Before the measured steps the store
# is loaded and left settled: memtables written out, and RocksDB's
# compactions finished. The shape that leaves is printed. The read steps
# share one load, since they change nothing; every step that writes gets a
# load of its own.
#
# How to read the columns:
#
#   - Times for RocksDB are db_bench's: whole microseconds, counted in
#     buckets, with percentiles estimated inside a bucket. bean-bench's are
#     exact. Below about ten microseconds the two are not comparable to
#     better than a microsecond or so.
#   - CPU per operation is the CPU time of the whole process, all threads,
#     less that of a process which only opens the store. For bean it includes
#     sorting the recorded times, and in readwhilewriting the writer's wait
#     for its turn, which spins.
#   - bean is single-threaded. Its rows with more than one thread run the
#     threads one at a time behind the benchmark's own lock, so they measure
#     that lock as much as the store. The one-thread rows are the store.
#
# What this cannot show until bean compacts: a store larger than memory, and
# a store that has been overwritten long enough to reach a steady state. bean
# holds at most eight tables today, so the loads here are kept small enough
# to fit.
#
# Settings, all from the environment:
#
#   BEAN_BENCH     the bean-bench program     (zig-out/bin/bean-bench)
#   DB_BENCH       RocksDB's db_bench         (~/code/bean-bench/rocksdb/bin/db_bench)
#   WORK_DIR       where the stores go; must be on a real disk. The script
#                  makes and removes WORK_DIR/rocksdb and WORK_DIR/bean
#   OUT_DIR        where the results and the raw output go
#   RUNS           how many times to run everything            (3)
#   DURATION       seconds each measured step runs             (10)
#   MEMORY_MAX     memory limit for each store's runs          (2G)
#   WRITE_THREADS  client threads for the writes scenario      ("1 4 16 64")
#   READ_THREADS   reader threads for the reads scenario       ("1 16")
#   WRITE_LOAD     keys loaded before the writes are measured  (500000)
#   READ_LOAD      keys loaded before the reads are measured   (1000000)
#   ROCKS_CACHE    bytes in RocksDB's block cache              (536870912)

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SELF=$HERE/$(basename "$0")

BEAN_BENCH=${BEAN_BENCH:-$HERE/../zig-out/bin/bean-bench}
DB_BENCH=${DB_BENCH:-$HOME/code/bean-bench/rocksdb/bin/db_bench}
WORK_DIR=${WORK_DIR:-$HOME/code/bean-bench/work}
OUT_DIR=${OUT_DIR:-$HOME/code/bean-bench/results-$(date +%Y%m%d-%H%M%S)}
RUNS=${RUNS:-3}
DURATION=${DURATION:-10}
MEMORY_MAX=${MEMORY_MAX:-2G}
WRITE_THREADS=${WRITE_THREADS:-"1 4 16 64"}
READ_THREADS=${READ_THREADS:-"1 16"}
WRITE_LOAD=${WRITE_LOAD:-500000}
READ_LOAD=${READ_LOAD:-1000000}
ROCKS_CACHE=${ROCKS_CACHE:-536870912}

KEY_SIZE=16
VALUE_SIZE=100
LOAD_BATCH=1000
SEEK_NEXTS=10
# The seed for the random keys of a load, and of a measured step. They must
# differ: with the same seed a measured step would ask for the keys in the
# very order the load wrote them.
LOAD_SEED=1
MEASURE_SEED=2
# bean-bench stops at a count of operations as well as at the time limit, and
# sets aside room to time that many. These are counts it should not reach in
# DURATION seconds, shared out among the threads: more writes a second than
# the store can hold, and more reads a second than it does. A step that
# reaches its count anyway is marked STOPPED EARLY.
BEAN_WRITES_CAP=$((400000 * DURATION))
BEAN_READS_CAP=$((1000000 * DURATION))

export BEAN_BENCH DB_BENCH WORK_DIR OUT_DIR RUNS DURATION MEMORY_MAX
export WRITE_THREADS READ_THREADS WRITE_LOAD READ_LOAD ROCKS_CACHE

# ---------------------------------------------------------------------------
# Running one store's program

# Runs db_bench on the store in $db with the settings every RocksDB step
# shares. $num is the number of keys and $seed the seed for random keys.
run_rocksdb() {
    "$DB_BENCH" --db="$db" --num="$num" \
        --key_size=$KEY_SIZE --value_size=$VALUE_SIZE --seed="$seed" \
        --sync=1 --use_fsync=1 --compression_type=none \
        --bloom_bits=10 --cache_size="$ROCKS_CACHE" --max_background_jobs=8 \
        "$@"
}

# Runs bean-bench on the store in $db. bean has no settings to choose: it
# syncs every write and its limits are fixed when it is built.
run_bean() {
    "$BEAN_BENCH" --db="$db" --num="$num" \
        --key_size=$KEY_SIZE --value_size=$VALUE_SIZE --seed="$seed" \
        "$@"
}

run_engine() {
    if [ "$engine" = rocksdb ]; then
        run_rocksdb "$@"
    else
        run_bean "$@"
    fi
}

# Loads the store. Its output goes to the raw file named by $1, and the lines
# that say what shape the store was left in are printed.
load_step() {
    local raw=$1
    shift
    seed=$LOAD_SEED
    if ! run_engine "$@" >"$raw" 2>&1; then
        echo "load failed; see $raw" >&2
        exit 1
    fi
    if [ "$engine" = rocksdb ]; then
        # The level table: a heading, then one line for each level. Only the
        # levels that hold files are worth printing.
        awk -v label="$scenario/$engine" '
            /^Level Files Size/ { in_levels = 1; next }
            in_levels && /^-+$/ { next }
            in_levels && NF == 3 && $2 > 0 {
                printf "    %-16s level %s: %s files, %s MB\n", label, $1, $2, $3
            }
            in_levels && NF != 3 { in_levels = 0 }
        ' "$raw"
    else
        awk -v label="$scenario/$engine" '
            /^Tables:/ { printf "    %-16s %s\n", label, $0 }
            /the store is full/ { printf "    %-16s THE STORE FILLED DURING THE LOAD\n", label }
        ' "$raw"
    fi
}

# Runs one measured step and adds its line to the results.
#
#     measure <workload> <threads> <args for the program...>
#
# The program must run exactly one workload, so that its output holds one
# result. The CPU time reported for it is the CPU time of the process less
# that of a process which only opens the store and closes it, measured just
# before.
measure() {
    local workload=$1 threads=$2
    shift 2
    local raw="$raw_dir/$engine-$scenario-$workload-t$threads-run$run.txt"
    local cpu="$raw.cpu"
    local open_cpu="$raw.open-cpu"
    seed=$MEASURE_SEED

    local TIMEFORMAT='%U %S %R'
    if ! { time run_engine --use_existing_db=1 --benchmarks=levelstats \
            >/dev/null 2>&1; } 2>"$open_cpu"; then
        echo "could not open the store before $workload" >&2
        exit 1
    fi
    if ! { time run_engine --use_existing_db=1 --benchmarks="$workload" \
            --threads="$threads" --duration="$DURATION" --histogram=1 \
            "$@" >"$raw" 2>&1; } 2>"$cpu"; then
        echo "$workload failed; see $raw" >&2
        exit 1
    fi

    awk -v scenario="$scenario" -v workload="$workload" -v threads="$threads" \
        -v engine="$engine" -v run="$run" -v cpu_file="$cpu" \
        -v open_cpu_file="$open_cpu" -v duration="$DURATION" '
        BEGIN {
            getline cpu_line < cpu_file
            split(cpu_line, cpu_parts, " ")
            getline open_cpu_line < open_cpu_file
            split(open_cpu_line, open_cpu_parts, " ")
            cpu_seconds = cpu_parts[1] + cpu_parts[2] - open_cpu_parts[1] - open_cpu_parts[2]
            if (cpu_seconds < 0) { cpu_seconds = 0 }
            ops_per_second = "-"; operations = 0
            p50 = "-"; p99 = "-"; p999 = "-"; slowest = "-"
            syncs = 0; note = ""
        }
        # The result line: "name : N micros/op N ops/sec N seconds N operations; ..."
        / micros\/op .* ops\/sec / && !have_result {
            have_result = 1
            for (i = 1; i <= NF; i++) {
                if ($i == "ops/sec") { ops_per_second = $(i - 1) }
                if ($i == "operations;") { operations = $(i - 1) }
                if ($i == "seconds") { seconds = $(i - 1) }
                # bean-bench, in readwhilewriting: "(N writes meanwhile)".
                if ($i == "writes" && $(i + 1) ~ /^meanwhile/) {
                    note = note " " substr($(i - 1), 2) " writes"
                }
                # "(N of M found)". With threads, db_bench prints the
                # counts of one thread, so only the share is kept.
                if ($i == "of" && $(i + 2) ~ /^found/ && $(i + 1) > 0) {
                    note = note sprintf(" found %.0f%%", 100 * substr($(i - 1), 2) / $(i + 1))
                }
                if ($i == "syncs,") { syncs = substr($(i - 1), 2) }
            }
            if ($0 ~ /the store is full/) { note = note " STORE FULL" }
            if (seconds < 0.9 * duration) { note = note " STOPPED EARLY" }
        }
        # The first spread of times after the result is the one to report.
        /^Min: / && have_result && !have_min { have_min = 1; slowest = $6 }
        /^Percentiles: / && have_result && !have_percentiles {
            have_percentiles = 1
            p50 = $3; p99 = $7; p999 = $9
        }
        # RocksDB counts its syncs of the log here.
        /^rocksdb\.wal\.synced COUNT/ { syncs = $4 }
        END {
            if (!have_result) {
                print "no result line in the output" > "/dev/stderr"
                exit 1
            }
            ops_per_sync = "-"
            if (syncs > 0) { ops_per_sync = sprintf("%.1f", operations / syncs) }
            cpu_micros = "-"
            if (operations > 0) { cpu_micros = sprintf("%.2f", cpu_seconds * 1000000 / operations) }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                scenario, workload, threads, engine, run, ops_per_second,
                p50, p99, p999, slowest, ops_per_sync, cpu_micros, note
        }
    ' "$raw" >>"$OUT_DIR/results.tsv"

    tail -n 1 "$OUT_DIR/results.tsv" | print_rows
}

# Prints result lines from standard input as a table row each.
print_rows() {
    awk -F '\t' '{
        printf "    %-17s %3s  %-8s %10s %9s %9s %10s %10s %8s %8s %s\n",
            $2, $3, $4, $6, $7, $8, $9, $10, $11, $12, $13
    }'
}

print_heading() {
    printf "    %-17s %3s  %-8s %10s %9s %9s %10s %10s %8s %8s\n" \
        workload thr store ops/sec "p50 us" "p99 us" "p99.9 us" "max us" ops/sync "cpu us/op"
}

# ---------------------------------------------------------------------------
# The scenarios, for one store

# Many clients, one durable write each, into a store that holds WRITE_LOAD
# keys. The store is loaded again for each thread count, so that every count
# starts from the same shape.
scenario_writes() {
    num=$WRITE_LOAD
    local threads
    for threads in $WRITE_THREADS; do
        rm -rf "$db"
        if [ "$engine" = rocksdb ]; then
            load_step "$raw_dir/$engine-writes-load-t$threads-run$run.txt" \
                --benchmarks=fillseq,flush,waitforcompaction,levelstats --batch_size=$LOAD_BATCH
            # db_bench looks at the clock once in 1000 operations unless
            # told otherwise, which at a few hundred writes a second would
            # run well past the time limit.
            measure overwrite "$threads" --batch_size=1 --statistics=1 \
                --ops_between_duration_checks=1
        else
            load_step "$raw_dir/$engine-writes-load-t$threads-run$run.txt" \
                --benchmarks=fillseq,flush,levelstats --batch_size=$LOAD_BATCH
            measure overwrite "$threads" --batch_size=1 --writes=$((BEAN_WRITES_CAP / threads))
        fi
    done
}

# Reads from a store that was filled in key order and then overwritten once
# in random order, so that its tables overlap the way a used store's do, and
# every key from 0 to READ_LOAD is present.
load_for_reads() {
    num=$READ_LOAD
    rm -rf "$db"
    if [ "$engine" = rocksdb ]; then
        load_step "$raw_dir/$engine-reads-load-run$run.txt" \
            --benchmarks=fillseq,overwrite,flush,waitforcompaction,levelstats --batch_size=$LOAD_BATCH
    else
        load_step "$raw_dir/$engine-reads-load-run$run.txt" \
            --benchmarks=fillseq,overwrite,flush,levelstats --batch_size=$LOAD_BATCH
    fi
}

scenario_reads() {
    load_for_reads

    local threads reads
    for threads in $READ_THREADS; do
        reads=$((BEAN_READS_CAP / threads))
        measure readrandom "$threads" --reads=$reads
        measure readmissing "$threads" --reads=$reads
    done
    # bean-bench scans from one thread only.
    measure seekrandom 1 --reads=$BEAN_READS_CAP --seek_nexts=$SEEK_NEXTS
    # This one writes to the store, so each run of it gets a new load.
    for threads in $READ_THREADS; do
        load_for_reads
        reads=$((BEAN_READS_CAP / threads))
        measure readwhilewriting "$threads" --reads=$reads
    done
}

# Runs one scenario for one store. This is what runs under the memory limit.
run_one() {
    engine=$1
    scenario=$2
    run=$3
    db=$WORK_DIR/$engine
    raw_dir=$OUT_DIR/raw
    mkdir -p "$raw_dir" "$WORK_DIR"

    "scenario_$scenario"
    rm -rf "$db"

    # The most memory this scenario's processes held at once, page cache
    # included, if this is running in a control group of its own.
    local group peak
    group=$(awk -F : '$1 == "0" { print $3 }' /proc/self/cgroup 2>/dev/null || true)
    peak=/sys/fs/cgroup$group/memory.peak
    if [ -n "$group" ] && [ -r "$peak" ]; then
        printf "    %-16s peak memory %d MB\n" "$scenario/$engine" $(($(cat "$peak") / 1024 / 1024))
    fi
}

# ---------------------------------------------------------------------------
# The driver

# Runs a command under the memory limit, in a control group of its own, so
# that the page cache its files take up counts against it too.
limited() {
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --scope --quiet \
            -p MemoryMax="$MEMORY_MAX" -p MemorySwapMax=0 "$@"
    else
        "$@"
    fi
}

# Prints the mean of every column over the runs, one row for each workload,
# thread count and store, in the order they were first seen.
print_means() {
    awk -F '\t' '
        {
            key = $1 FS $2 FS $3 FS $4
            if (!(key in seen)) { seen[key] = 1; order[++count] = key }
            runs[key]++
            for (column = 6; column <= 12; column++) {
                if ($column != "-") {
                    total[key, column] += $column
                    have[key, column]++
                }
            }
            if ($13 ~ /STORE FULL/) { full[key] = full[key] " STORE FULL" }
            if ($13 ~ /STOPPED EARLY/) { full[key] = full[key] " STOPPED EARLY" }
        }
        END {
            for (n = 1; n <= count; n++) {
                key = order[n]
                split(key, parts, FS)
                line = parts[1] FS parts[2] FS parts[3] FS parts[4] FS runs[key]
                for (column = 6; column <= 12; column++) {
                    if (have[key, column] > 0) {
                        mean = total[key, column] / have[key, column]
                        if (column == 6) { line = line FS sprintf("%.0f", mean) }
                        else { line = line FS sprintf("%.2f", mean) }
                    } else {
                        line = line FS "-"
                    }
                }
                print line FS full[key]
            }
        }
    ' "$OUT_DIR/results.tsv"
}

main() {
    for program in "$BEAN_BENCH" "$DB_BENCH"; do
        if [ ! -x "$program" ]; then
            echo "not found: $program" >&2
            exit 1
        fi
    done
    mkdir -p "$WORK_DIR" "$OUT_DIR"

    # A store on a memory-backed directory never waits for a disk, which
    # makes every write result meaningless.
    local filesystem
    filesystem=$(stat -f -c %T "$WORK_DIR" 2>/dev/null || echo unknown)
    if [ "$filesystem" = tmpfs ] || [ "$filesystem" = ramfs ]; then
        echo "$WORK_DIR is on $filesystem, not a disk; set WORK_DIR" >&2
        exit 1
    fi

    : >"$OUT_DIR/results.tsv"
    {
        echo "bean against RocksDB"
        echo "  date         $(date)"
        echo "  machine      $(uname -srm), $(nproc 2>/dev/null || echo '?') cores"
        echo "  disk         $WORK_DIR ($filesystem)"
        if command -v systemd-run >/dev/null 2>&1; then
            echo "  memory limit $MEMORY_MAX for each store's runs"
        else
            echo "  memory limit none: systemd-run was not found"
        fi
        echo "  each step    $DURATION seconds"
        echo "  entries      $KEY_SIZE-byte keys, $VALUE_SIZE-byte values"
        echo "  rocksdb      $("$DB_BENCH" --version 2>/dev/null | head -n 1)"
        echo "               sync=1 use_fsync=1 no compression, bloom_bits=10,"
        echo "               cache_size=$ROCKS_CACHE, max_background_jobs=8"
        echo "  bean         $(cd "$HERE/.." && git describe --always --dirty 2>/dev/null || echo '?') (the source tree; $BEAN_BENCH is not checked against it)"

        local run scenario engine
        for run in $(seq 1 "$RUNS"); do
            echo
            echo "run $run   (load: $(uptime | sed 's/.*load average/load average/'))"
            for scenario in writes reads; do
                echo
                echo "  $scenario"
                print_heading
                for engine in rocksdb bean; do
                    limited "$SELF" one "$engine" "$scenario" "$run"
                done
            done
        done

        echo
        echo "means over $RUNS runs"
        print_heading
        print_means | awk -F '\t' 'BEGIN { OFS = "\t" } { print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' | print_rows
        echo
        echo "notes"
        echo "  - RocksDB's times are whole microseconds counted in buckets; bean's are exact."
        echo "  - cpu us/op is the whole process, all threads, less a process that only opens the store."
        echo "  - bean's rows with more than one thread run behind the benchmark's lock, one"
        echo "    thread at a time; the one-thread rows are the store."
        echo
        echo "raw output: $OUT_DIR/raw"
    } 2>&1 | tee "$OUT_DIR/results.txt"

    # Only what this script made. The directory itself goes only if that
    # leaves it empty.
    rm -rf "$WORK_DIR/rocksdb" "$WORK_DIR/bean"
    rmdir "$WORK_DIR" 2>/dev/null || true
}

if [ "${1:-}" = one ]; then
    run_one "$2" "$3" "$4"
else
    main
fi
