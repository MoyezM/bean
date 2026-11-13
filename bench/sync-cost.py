#!/usr/bin/env python3
"""Measures what one durable write costs on this disk, done several ways.

bean's log today appends with a buffered write and then calls fsync. The
alternative is TigerBeetle's: open the file with O_DIRECT and O_DSYNC, write
whole sectors over space that was allocated and written beforehand, and treat
the write as durable when it returns, with no separate sync.

Each method writes the same number of records of the same size, one at a
time, and times each one from the start of the write to the point where the
data is durable. Linux only. Run it on the disk the store will use:

    python3 bench/sync-cost.py /path/on/that/disk

The writes are blocking calls, not io_uring. The time a durable write takes
is set by the file system and the disk, so it is the same either way; what
io_uring changes is whether the caller can do other work meanwhile.
"""

import mmap
import os
import sys
import time

SECTOR = 4096
RECORD_SIZES = [SECTOR, 64 * 1024, 1024 * 1024]
WRITES = 300


def aligned_buffer(size):
    # O_DIRECT needs the buffer's address to be a multiple of the sector
    # size. An anonymous mapping starts on a page boundary.
    buffer = mmap.mmap(-1, size)
    buffer.write(os.urandom(size))
    return buffer


def create_file(path, flags):
    return os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC | flags, 0o600)


def sync_file_and_directory(fd, path):
    os.fsync(fd)
    directory = os.open(os.path.dirname(path), os.O_RDONLY)
    os.fsync(directory)
    os.close(directory)


def allocate_only(fd, path, size):
    # Reserves the space. The blocks are marked "not yet written", so the
    # first write to each one still has to update the file's metadata.
    os.posix_fallocate(fd, 0, size)
    sync_file_and_directory(fd, path)


def allocate_and_write(fd, path, size):
    # Reserves the space and writes zeros over all of it, so that later
    # writes change only data and never the file's metadata.
    os.posix_fallocate(fd, 0, size)
    zeros = bytes(1024 * 1024)
    offset = 0
    while offset < size:
        length = min(len(zeros), size - offset)
        os.pwrite(fd, zeros[:length], offset)
        offset += length
    sync_file_and_directory(fd, path)


def no_setup(fd, path, size):
    sync_file_and_directory(fd, path)


def no_sync(fd):
    pass


# name, open flags, how the file is prepared, what follows each write
METHODS = [
    ("buffered append + fsync (bean today)", 0, no_setup, os.fsync),
    ("buffered append + fdatasync", 0, no_setup, os.fdatasync),
    ("buffered overwrite + fdatasync", 0, allocate_and_write, os.fdatasync),
    ("O_DSYNC overwrite", os.O_DSYNC, allocate_and_write, no_sync),
    ("O_DIRECT overwrite + fdatasync", os.O_DIRECT, allocate_and_write, os.fdatasync),
    ("O_DIRECT+O_DSYNC append", os.O_DIRECT | os.O_DSYNC, no_setup, no_sync),
    ("O_DIRECT+O_DSYNC, allocated only", os.O_DIRECT | os.O_DSYNC, allocate_only, no_sync),
    ("O_DIRECT+O_DSYNC overwrite (TigerBeetle)", os.O_DIRECT | os.O_DSYNC, allocate_and_write, no_sync),
]


def measure(path, record_size, flags, prepare, after_write):
    buffer = aligned_buffer(record_size)
    fd = create_file(path, flags)
    prepare(fd, path, record_size * WRITES)

    latencies_us = []
    for index in range(WRITES):
        start = time.perf_counter_ns()
        written = os.pwrite(fd, buffer, index * record_size)
        after_write(fd)
        end = time.perf_counter_ns()
        if written != record_size:
            raise RuntimeError("short write: %d of %d bytes" % (written, record_size))
        latencies_us.append((end - start) / 1000.0)

    os.close(fd)
    os.unlink(path)
    buffer.close()

    latencies_us.sort()
    return latencies_us


def percentile(sorted_values, fraction):
    index = min(len(sorted_values) - 1, int(len(sorted_values) * fraction))
    return sorted_values[index]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: sync-cost.py <directory on the disk to measure>")
    directory = os.path.abspath(sys.argv[1])
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "sync-cost.tmp")

    print("%d writes per row, one at a time; microseconds per durable write" % WRITES)
    for record_size in RECORD_SIZES:
        print()
        print("record size %d bytes" % record_size)
        print("  %-42s %9s %9s %9s %9s" % ("method", "min", "median", "p99", "max"))
        for name, flags, prepare, after_write in METHODS:
            latencies_us = measure(path, record_size, flags, prepare, after_write)
            print("  %-42s %9.0f %9.0f %9.0f %9.0f" % (
                name,
                latencies_us[0],
                percentile(latencies_us, 0.50),
                percentile(latencies_us, 0.99),
                latencies_us[-1],
            ))


if __name__ == "__main__":
    main()
