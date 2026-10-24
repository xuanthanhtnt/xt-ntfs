# Changelog

## [1.0.0] - 2026-10-24

First release.

- Read-write NTFS on macOS 13 Ventura through macOS 27, Apple silicon and Intel (universal binary).
- Paragon-style interface: volume sidebar with status, read-only/nobrowse badges and eject buttons; Mount/Unmount, Verify, Erase and Startup actions; volume details, usage bar with file categories; per-volume options (Spotlight, read-only, no automount).
- Automatic read-write mounting: a LaunchDaemon blocks the read-only system mount of NTFS volumes and mounts them with the XT engine as soon as they are connected.
- XT engine: ntfs-3g 2026.9.28 with a new raw-device I/O layer (sector-aligned large transfers on `/dev/rdisk`, write-back cache for metadata, background flusher) and tuned macFUSE options. Three performance profiles: Compatible, Balanced, Turbo.
- Hibernated (Fast Startup) and unclean volumes handled by policy: verify, mount read-only, or remove hibernation data.
- Verify / repair (ntfsfix), erase to NTFS, ExFAT, FAT32, APFS or Mac OS Extended, rename.
- Built-in benchmark (sequential write/read with cache bypass, small files) with history, to compare drivers on the same disk.
- Menu bar extra, notifications, light/dark appearance, English and Vietnamese.
- In-app updates via Sparkle 2 with EdDSA-signed releases.
