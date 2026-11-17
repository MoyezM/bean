#!/usr/bin/env bash
#
# Durable single writes into RocksDB once it is using its old log files
# again.
#
# With recycle_log_file_num set, RocksDB keeps a log file it no longer
# needs and writes its next log over it. An append to such a log overwrites
# space that already holds data, so its sync changes no file metadata and is
# several times cheaper. This is RocksDB at its best for a durable write,
# and it is what bean's log always does.
#
# bench/compare-rocksdb.sh cannot show it: a RocksDB process starts on a new
# log, and only gets a recycled one at its third log. So each step here is
# one process that does the same number of writes three times, with a flush
# after the first and the second. A flush starts a new log. The first two
# rounds are on new logs; the third is on a recycled one, and is the one to
# read. All three are printed.
#
# The rounds are a count of writes and not a length of time on purpose. A
# recycled log is only as long as it was written the first time. The third
# round writes exactly as much as the first did, so all of it lands on
# space the first round wrote.
#
# db_bench has no flag for recycling, so it is given an options file: the
# one RocksDB itself writes for the settings compare-rocksdb.sh uses, with
# recycle_log_file_num changed.
#
# Settings, from the environment: DB_BENCH, WORK_DIR, THREADS ("1 4 16 64"),
# LOAD (500000), and WRITES, the writes each thread does in a round (1000).

set -euo pipefail

DB_BENCH=${DB_BENCH:-$HOME/code/bean-bench/rocksdb/bin/db_bench}
WORK_DIR=${WORK_DIR:-$HOME/code/bean-bench/work-recycled}
WRITES=${WRITES:-1000}
THREADS=${THREADS:-"1 4 16 64"}
LOAD=${LOAD:-500000}

db=$WORK_DIR/rocksdb
options=$WORK_DIR/options-recycle.ini
mkdir -p "$WORK_DIR"

run_rocksdb() {
    "$DB_BENCH" --db="$db" --num="$LOAD" --key_size=16 --value_size=100 \
        --sync=1 --use_fsync=0 --compression_type=none \
        --bloom_bits=10 --cache_size=536870912 --max_background_jobs=8 \
        "$@"
}

# The options file RocksDB writes for these settings, with recycling on.
rm -rf "$db"
run_rocksdb --benchmarks=fillseq --batch_size=1000 >/dev/null 2>&1
written=$(ls "$db"/OPTIONS-* | tail -n 1)
sed "s/recycle_log_file_num=0/recycle_log_file_num=4/" "$written" >"$options"
if ! grep -q "recycle_log_file_num=4" "$options"; then
    echo "could not turn recycling on in $options" >&2
    exit 1
fi

echo "RocksDB, durable single writes, $WRITES from each thread a round"
echo "rounds 1 and 2 are on new log files; round 3 is on a recycled one"
for threads in $THREADS; do
    rm -rf "$db"
    run_rocksdb --options_file="$options" --batch_size=1000 \
        --benchmarks=fillseq,overwrite,flush,waitforcompaction >/dev/null 2>&1
    echo
    echo "threads $threads"
    run_rocksdb --options_file="$options" --use_existing_db=1 --batch_size=1 \
        --threads="$threads" --writes="$WRITES" \
        --histogram=1 --benchmarks=overwrite,flush,overwrite,flush,overwrite 2>&1 |
        awk '
            /^overwrite / { round++; printf "  round %d: %s ops/sec", round, $5 }
            /^Percentiles: / { printf "   p50 %s us, p99 %s us\n", $3, $7 }
        '
done

rm -rf "$db" "$options"
rmdir "$WORK_DIR" 2>/dev/null || true
