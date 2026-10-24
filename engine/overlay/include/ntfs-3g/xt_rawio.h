/*
 * xt_rawio.h - XT NTFS high-throughput device I/O layer for libntfs-3g.
 *
 * Copyright (c) 2026 XT NTFS contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Why this exists
 * ---------------
 * On macOS, I/O on a block device node (/dev/diskXsY) goes through the
 * kernel buffer cache in small, fixed-size buffers, which makes large
 * sequential transfers slow. The character ("raw") node (/dev/rdiskXsY)
 * moves data in large transfers, but every request must be aligned to
 * the device sector size, which libntfs-3g does not guarantee.
 *
 * This layer sits under libntfs-3g's unix device operations and provides:
 *   - sector-aligned access to raw devices (read-modify-write at the edges),
 *   - large transfers straight to/from the device (no extra copies when
 *     the caller's buffer is suitably aligned),
 *   - a write-back cache for small metadata I/O (MFT records, index
 *     blocks, bitmaps), flushed in offset order by a background thread,
 *     on sync, on close and before fork(). Sector-aligned writes into
 *     space that is not cached do not read the surrounding cache line
 *     first (new files cost no device reads),
 *   - read-ahead for sequential reads: background threads fetch the next
 *     chunks while FUSE hands the current one to the application.
 *
 * Tuning (environment variables, read when the device is opened):
 *   XTNTFS_RAWIO=0            disable this layer (plain unix I/O)
 *   XTNTFS_CACHE_MB=64        cache size in MiB (0 = no cache)
 *   XTNTFS_LINE_KB=256        cache line size in KiB (power of two)
 *   XTNTFS_DIRECT_KB=1024     requests >= this size bypass the cache
 *   XTNTFS_DIRTY_MB=16        flush synchronously above this much dirty data
 *   XTNTFS_FLUSH_MS=1000      background flush delay for dirty data
 *   XTNTFS_RA_KB=1024         read-ahead chunk size in KiB (0 = off)
 *   XTNTFS_RA_DEPTH=4         chunks kept ahead of a sequential reader
 *   XTNTFS_RA_THREADS=2       read-ahead threads (device queue depth)
 *   XTNTFS_STATS=1            print cache and request size statistics
 *                             to stderr when the device is closed
 *   XTNTFS_SIMULATE_LATENCY_US, XTNTFS_SIMULATE_MBPS
 *                             (testing) make each device request take as
 *                             long as on a real disk
 *   XTNTFS_SIMULATE_RAW=N     treat any device/file as raw with N-byte sectors
 *                             (testing; misaligned device I/O aborts)
 *   XTNTFS_SIMULATE_ODIRECT=1 (Linux testing) open with O_DIRECT
 */

#ifndef _NTFS_XT_RAWIO_H
#define _NTFS_XT_RAWIO_H

#include "types.h"

struct xt_raw;

/* Returns 1 if the layer should be used for this open file descriptor. */
int xt_raw_wanted(int fd);

/* Extra open(2) flags to use for this device (e.g. O_DIRECT in tests). */
int xt_raw_open_flags(void);

/*
 * Attach the layer to an open descriptor. Returns NULL with errno set on
 * failure. The descriptor stays owned by the caller.
 */
struct xt_raw *xt_raw_attach(int fd, int writable, const char *name);

s64 xt_raw_pread(struct xt_raw *r, void *buf, s64 count, s64 offset);
s64 xt_raw_pwrite(struct xt_raw *r, const void *buf, s64 count, s64 offset);

/* Sequential helpers (current position kept by the layer). */
s64 xt_raw_seek(struct xt_raw *r, s64 offset, int whence);
s64 xt_raw_read(struct xt_raw *r, void *buf, s64 count);
s64 xt_raw_write(struct xt_raw *r, const void *buf, s64 count);

/* Write back all dirty cached data (does not issue a device cache flush). */
int xt_raw_flush(struct xt_raw *r);

/* Flush, stop the background thread and free. Returns -1 if data was lost. */
int xt_raw_detach(struct xt_raw *r);

/* Statistics for diagnostics (may be NULL pointers). */
void xt_raw_stats(struct xt_raw *r, u64 *hits, u64 *misses,
		u64 *direct_bytes, u64 *flushed_bytes);

#endif /* _NTFS_XT_RAWIO_H */
