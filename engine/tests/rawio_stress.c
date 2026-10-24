/*
 * rawio_stress.c - randomized correctness test for the XT raw I/O layer.
 *
 * Runs random reads/writes/seeks/syncs/forks through libntfs-3g's unix
 * device operations against a scratch file while keeping an in-memory
 * reference image, then checks every read and the final on-disk content.
 *
 * Build (from an ntfs-3g tree built by engine/build-ntfs3g.sh):
 *   cc -O2 -I$SRC -I$SRC/include/ntfs-3g -DHAVE_CONFIG_H rawio_stress.c \
 *      $SRC/libntfs-3g/.libs/libntfs-3g.a -lpthread -o rawio_stress
 * Run:
 *   XTNTFS_SIMULATE_RAW=512 ./rawio_stress /tmp/scratch.img 64 20000 1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>

#include "types.h"
#include "device.h"

static u64 rng_state;

static u64 rnd(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return rng_state;
}

static s64 rnd_range(s64 lo, s64 hi)	/* inclusive */
{
	return lo + (s64)(rnd() % (u64)(hi - lo + 1));
}

static s64 pick_size(s64 devsize)
{
	switch (rnd() % 10) {
	case 0: case 1: case 2:
		return rnd_range(1, 4096);		/* small, metadata-like */
	case 3: case 4:
		return rnd_range(1, 1024) * 512;	/* sector multiples */
	case 5:
		return 1024;				/* MFT record */
	case 6:
		return rnd_range(4096, 300 << 10);	/* medium */
	case 7:
		return rnd_range(1, 64) * 65536;	/* large, aligned */
	case 8:
		return rnd_range(100 << 10, 6 << 20);	/* large, unaligned */
	default:
		return rnd_range(1, devsize / 8);
	}
}

static s64 pick_off(s64 devsize, s64 len)
{
	s64 o;

	switch (rnd() % 6) {
	case 0:
		o = rnd_range(0, 64) * 512;		/* near start */
		break;
	case 1:
		o = devsize - len - rnd_range(0, 4096);	/* near end */
		break;
	case 2:
		o = rnd_range(0, devsize / 4096) * 4096;
		break;
	default:
		o = rnd_range(0, devsize);
	}
	if (o < 0)
		o = 0;
	if (o > devsize)
		o = devsize;
	return o;
}

static int fail(const char *what, s64 off, s64 len)
{
	fprintf(stderr, "FAIL: %s off=%lld len=%lld errno=%d\n", what,
		(long long)off, (long long)len, errno);
	exit(1);
}

int main(int argc, char **argv)
{
	const char *path;
	s64 devsize, i, ops, pos = 0;
	char *ref, *buf;
	struct ntfs_device *dev;
	int fd, use_fork, forked = 0;
	u64 seed;
	unsigned long nread = 0, nwrite = 0, nsync = 0;

	if (argc < 5) {
		fprintf(stderr, "usage: %s file size_mb ops fork [seed]\n",
			argv[0]);
		return 2;
	}
	path = argv[1];
	devsize = (s64)atoll(argv[2]) << 20;
	if (getenv("EXTRA_BYTES"))	/* odd device sizes */
		devsize += atoll(getenv("EXTRA_BYTES"));
	ops = atoll(argv[3]);
	use_fork = atoi(argv[4]);
	seed = argc > 5 ? strtoull(argv[5], NULL, 10) : (u64)time(NULL);
	rng_state = seed | 1;
	printf("seed=%llu size=%lld ops=%lld\n", (unsigned long long)seed,
	       (long long)devsize, (long long)ops);

	ref = malloc(devsize);
	buf = malloc(8 << 20);
	if (!ref || !buf)
		return 1;
	for (i = 0; i < devsize; i += 8)
		*(u64 *)(ref + i) = rnd();

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0 || write(fd, ref, devsize) != devsize)
		fail("init", 0, devsize);
	fsync(fd);
	close(fd);

	dev = ntfs_device_alloc(path, 0, &ntfs_device_unix_io_ops, NULL);
	if (!dev || dev->d_ops->open(dev, O_RDWR))
		fail("open", 0, 0);

	for (i = 0; i < ops; i++) {
		s64 len = pick_size(devsize), off, n, exp;
		int op = (int)(rnd() % 100);

		if (len > (8 << 20))
			len = 8 << 20;
		off = pick_off(devsize, len);
		exp = off + len > devsize ? devsize - off : len;

		if (op < 40) {				/* pread */
			n = dev->d_ops->pread(dev, buf, len, off);
			if (n != exp)
				fail("pread size", off, len);
			if (n > 0 && memcmp(buf, ref + off, n))
				fail("pread data", off, len);
			nread++;
		} else if (op < 85) {			/* pwrite */
			s64 k;
			for (k = 0; k < len; k += 8)
				*(u64 *)(buf + k) = rnd();
			NDevSetDirty(dev);
			n = dev->d_ops->pwrite(dev, buf, len, off);
			if (off >= devsize) {
				if (n != -1)
					fail("pwrite past end", off, len);
			} else {
				if (n != exp)
					fail("pwrite size", off, len);
				memcpy(ref + off, buf, n);
			}
			nwrite++;
		} else if (op < 90) {			/* seek + read */
			if (dev->d_ops->seek(dev, off, SEEK_SET) != off)
				fail("seek", off, 0);
			n = dev->d_ops->read(dev, buf, len);
			if (n != exp || (n > 0 && memcmp(buf, ref + off, n)))
				fail("read", off, len);
			pos = off + n;
		} else if (op < 95) {			/* seek + write */
			s64 k;
			if (off >= devsize)
				continue;
			for (k = 0; k < len; k += 8)
				*(u64 *)(buf + k) = rnd();
			dev->d_ops->seek(dev, off, SEEK_SET);
			n = dev->d_ops->write(dev, buf, len);
			if (n != exp)
				fail("write", off, len);
			memcpy(ref + off, buf, n);
			pos = off + n;
			(void)pos;
		} else if (op < 98) {
			if (dev->d_ops->sync(dev))
				fail("sync", 0, 0);
			nsync++;
		} else if (op == 98) {
			usleep(150000);	/* let the background flusher run */
		} else if (use_fork && forked < 3) {
			/* Like daemon(): the parent leaves, the child goes on. */
			pid_t p = fork();
			if (p < 0)
				fail("fork", 0, 0);
			if (p > 0) {
				int st;
				waitpid(p, &st, 0);
				_exit(WIFEXITED(st) ? WEXITSTATUS(st) : 3);
			}
			forked++;
		}
	}

	if (dev->d_ops->close(dev))
		fail("close", 0, 0);
	ntfs_device_free(dev);

	fd = open(path, O_RDONLY);
	if (fd < 0 || pread(fd, buf, 0, 0) < 0)
		fail("reopen", 0, 0);
	for (i = 0; i < devsize; i += (8 << 20)) {
		s64 n = devsize - i < (8 << 20) ? devsize - i : (8 << 20);
		if (pread(fd, buf, n, i) != n)
			fail("verify read", i, n);
		if (memcmp(buf, ref + i, n)) {
			s64 k;
			for (k = 0; k < n && buf[k] == ref[i + k]; k++)
				;
			fail("final content", i + k, n);
		}
	}
	close(fd);
	printf("OK reads=%lu writes=%lu syncs=%lu forks=%d\n", nread, nwrite,
	       nsync, forked);
	return 0;
}
