# XT NTFS integration test

macOS 15.8.2 (arm64), Apple M1 (Virtual)

## Helper
- PASS install-engine.sh
- PASS helper socket exists
- PASS status request
- PASS status reports engine version
- PASS engine binaries installed
- PASS invalid disk name is rejected
- PASS ntfs-3g runs

## RAM disk
RAM disk: /dev/disk5
- PASS partition (MBR)
- PASS mkntfs
- PASS ntfs-3g.probe (read-write)
- PASS ntfsfix --no-action

## Engine throughput (ntfscp, 512 MiB file, no FUSE)
- block device (/dev/disk5s1): 3.28 s, 156 MB/s
- PASS data written via block device reads back intact
- raw device (/dev/rdisk5s1): 1.62 s, 316 MB/s
- PASS data written via raw device reads back intact
- PASS volume consistent after writes (ntfsfix)

## Helper operations
- PASS verify through helper
- PASS rename through helper
- PASS new label written
- PASS erase to ExFAT through helper
- PASS erase back to NTFS through helper
- PASS fresh NTFS volume is valid

Recent helper events:
- unmounted: disk5s1: Unmounted. It is safe to disconnect the volume.

## App
- PASS uninstall-engine.sh
- PASS helper removed

Failures: 0
