/*
 * xt_rawio.c - XT NTFS high-throughput device I/O layer for libntfs-3g.
 *
 * Copyright (c) 2026 XT NTFS contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * See xt_rawio.h for the design overview and tuning knobs.
 *
 * Invariants
 * ----------
 *  - Every byte held in a cache line is the most recent data for that
 *    device offset. Lines are always loaded completely before a partial
 *    update, so a line can be written back as a whole at any time.
 *  - A line's dirty range [dlo, dhi) is sector aligned and is the only part
 *    that may differ from the device.
 *  - All state is protected by one mutex per device; device I/O issued by
 *    this layer happens with that mutex held, so the background flusher can
 *    never write stale data over a newer direct write.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/time.h>

#if defined(__APPLE__) || defined(__DARWIN__)
#include <sys/disk.h>
#endif
#ifdef __linux__
#include <linux/fs.h>
#endif

#include "types.h"
#include "logging.h"
#include "xt_rawio.h"

#define XT_MIN_SECTOR		512u
#define XT_MEM_ALIGN		4096u
#define XT_DEF_LINE_KB		256u
#define XT_DEF_CACHE_MB		64u
#define XT_DEF_DIRECT_KB	1024u
#define XT_DEF_DIRTY_MB		16u
#define XT_DEF_FLUSH_MS		1000u
#define XT_BOUNCE_MIN		(4u << 20)
#define XT_EDGE_SIZE		(64u << 10)
#define XT_RETRY_NS		(2000ull * 1000000ull)
#define XT_TICK_MS		100

struct xt_line {
	s64 idx;			/* line number (offset >> line_shift) */
	u32 len;			/* valid bytes (short at device end) */
	u32 dlo, dhi;			/* dirty range, dlo == dhi: clean */
	char *data;
	struct xt_line *hnext;		/* hash chain */
	struct xt_line *prev, *next;	/* LRU list, head = most recent */
};

struct xt_raw {
	int fd;
	int writable;
	int simulate;
	u32 bsize;			/* sector size, power of two */
	s64 devsize;			/* usable size, multiple of bsize */
	s64 pos;			/* position for read()/write() */

	/* cache */
	u32 line_size;
	u32 line_shift;
	u32 nlines_max;
	u32 nlines;
	struct xt_line **hash;
	u32 hmask;
	struct xt_line *lru_head, *lru_tail;
	struct xt_line **sortbuf;
	u64 dirty_bytes;
	u64 dirty_max;
	u64 first_dirty_ns;
	u64 flush_ns;
	u32 direct_min;

	char *bounce;			/* aligned scratch for transfers */
	u32 bounce_size;
	char *edge;			/* aligned scratch for sector RMW */

	pthread_mutex_t mtx;
	pthread_cond_t cond;
	pthread_t thr;
	int thr_running;
	pid_t thr_pid;
	int no_thread;
	int closing;
	int io_error;			/* last background flush errno */
	u64 retry_after_ns;

	u64 st_hits, st_misses, st_direct, st_flushed;

	char *name;
	struct xt_raw *reg_next;
};

/* ------------------------------------------------------------------ */
/* registry + fork safety                                             */
/* ------------------------------------------------------------------ */

static pthread_mutex_t xt_reg_mtx = PTHREAD_MUTEX_INITIALIZER;
static struct xt_raw *xt_reg_head;
static pthread_once_t xt_atfork_once = PTHREAD_ONCE_INIT;

static int flush_all_locked(struct xt_raw *r);

static void xt_atfork_prepare(void)
{
	struct xt_raw *r;

	pthread_mutex_lock(&xt_reg_mtx);
	for (r = xt_reg_head; r; r = r->reg_next) {
		pthread_mutex_lock(&r->mtx);
		/* Leave nothing dirty behind: parent and child must not both
		 * own the same pending writes. */
		flush_all_locked(r);
	}
}

static void xt_atfork_parent(void)
{
	struct xt_raw *r;

	for (r = xt_reg_head; r; r = r->reg_next)
		pthread_mutex_unlock(&r->mtx);
	pthread_mutex_unlock(&xt_reg_mtx);
}

static void xt_atfork_child(void)
{
	struct xt_raw *r;

	for (r = xt_reg_head; r; r = r->reg_next) {
		/* Only the forking thread survives; it owns the mutex. */
		pthread_mutex_unlock(&r->mtx);
		pthread_cond_init(&r->cond, NULL);
		r->thr_running = 0;
	}
	pthread_mutex_unlock(&xt_reg_mtx);
}

static void xt_atfork_install(void)
{
	pthread_atfork(xt_atfork_prepare, xt_atfork_parent, xt_atfork_child);
}

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static u64 now_ns(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return (u64)tv.tv_sec * 1000000000ull + (u64)tv.tv_usec * 1000ull;
}

static unsigned long env_ulong(const char *name, unsigned long def)
{
	const char *s = getenv(name);
	char *end;
	unsigned long v;

	if (!s || !*s)
		return def;
	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno || *end)
		return def;
	return v;
}

static int is_pow2(u64 v)
{
	return v && !(v & (v - 1));
}

static u32 ilog2_u32(u32 v)
{
	u32 r = 0;

	while (v >>= 1)
		r++;
	return r;
}

static s64 round_down(s64 v, u32 a)
{
	return v - (v & (s64)(a - 1));
}

static s64 round_up(s64 v, u32 a)
{
	return round_down(v + a - 1, a);
}

static void check_align(struct xt_raw *r, s64 off, s64 len)
{
	if (((off | len) & (s64)(r->bsize - 1)) || off < 0 || len < 0) {
		ntfs_log_error("xt_rawio: misaligned device I/O off=%lld "
			"len=%lld bsize=%u\n", (long long)off,
			(long long)len, r->bsize);
		if (r->simulate)
			abort();
	}
}

/* Plain positioned I/O that retries on EINTR and partial transfers. */
static int sys_pread_full(int fd, void *buf, size_t len, s64 off)
{
	char *p = buf;

	while (len) {
		ssize_t n = pread(fd, p, len, (off_t)off);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0) {
			errno = EIO;
			return -1;
		}
		p += n;
		off += n;
		len -= (size_t)n;
	}
	return 0;
}

static int sys_pwrite_full(int fd, const void *buf, size_t len, s64 off)
{
	const char *p = buf;

	while (len) {
		ssize_t n = pwrite(fd, p, len, (off_t)off);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0) {
			errno = EIO;
			return -1;
		}
		p += n;
		off += n;
		len -= (size_t)n;
	}
	return 0;
}

/* Aligned device read; bounces when the memory buffer is misaligned. */
static int dev_read(struct xt_raw *r, void *buf, s64 len, s64 off)
{
	char *p = buf;

	check_align(r, off, len);
	if (!((uintptr_t)buf & (XT_MEM_ALIGN - 1)))
		return sys_pread_full(r->fd, buf, (size_t)len, off);
	while (len > 0) {
		u32 n = len > r->bounce_size ? r->bounce_size : (u32)len;
		if (sys_pread_full(r->fd, r->bounce, n, off))
			return -1;
		memcpy(p, r->bounce, n);
		p += n;
		off += n;
		len -= n;
	}
	return 0;
}

static int dev_write(struct xt_raw *r, const void *buf, s64 len, s64 off)
{
	const char *p = buf;

	check_align(r, off, len);
	if (!((uintptr_t)buf & (XT_MEM_ALIGN - 1)))
		return sys_pwrite_full(r->fd, buf, (size_t)len, off);
	while (len > 0) {
		u32 n = len > r->bounce_size ? r->bounce_size : (u32)len;
		memcpy(r->bounce, p, n);
		if (sys_pwrite_full(r->fd, r->bounce, n, off))
			return -1;
		p += n;
		off += n;
		len -= n;
	}
	return 0;
}

/* ------------------------------------------------------------------ */
/* cache lines                                                        */
/* ------------------------------------------------------------------ */

static u32 hash_idx(struct xt_raw *r, s64 idx)
{
	u64 h = (u64)idx * 0x9E3779B97F4A7C15ull;

	return (u32)(h >> 32) & r->hmask;
}

static struct xt_line *line_lookup(struct xt_raw *r, s64 idx)
{
	struct xt_line *l;

	for (l = r->hash[hash_idx(r, idx)]; l; l = l->hnext)
		if (l->idx == idx)
			return l;
	return NULL;
}

static void lru_unlink(struct xt_raw *r, struct xt_line *l)
{
	if (l->prev)
		l->prev->next = l->next;
	else
		r->lru_head = l->next;
	if (l->next)
		l->next->prev = l->prev;
	else
		r->lru_tail = l->prev;
	l->prev = l->next = NULL;
}

static void lru_push_head(struct xt_raw *r, struct xt_line *l)
{
	l->prev = NULL;
	l->next = r->lru_head;
	if (r->lru_head)
		r->lru_head->prev = l;
	r->lru_head = l;
	if (!r->lru_tail)
		r->lru_tail = l;
}

static void hash_insert(struct xt_raw *r, struct xt_line *l)
{
	u32 h = hash_idx(r, l->idx);

	l->hnext = r->hash[h];
	r->hash[h] = l;
}

static void hash_remove(struct xt_raw *r, struct xt_line *l)
{
	struct xt_line **pp = &r->hash[hash_idx(r, l->idx)];

	while (*pp) {
		if (*pp == l) {
			*pp = l->hnext;
			l->hnext = NULL;
			return;
		}
		pp = &(*pp)->hnext;
	}
}

static u32 line_len_for(struct xt_raw *r, s64 idx)
{
	s64 start = idx << r->line_shift;
	s64 left = r->devsize - start;

	if (left <= 0)
		return 0;
	return left < (s64)r->line_size ? (u32)left : r->line_size;
}

static void mark_clean(struct xt_raw *r, struct xt_line *l)
{
	if (l->dhi > l->dlo)
		r->dirty_bytes -= l->dhi - l->dlo;
	l->dlo = l->dhi = 0;
	if (!r->dirty_bytes)
		r->first_dirty_ns = 0;
}

static void mark_dirty(struct xt_raw *r, struct xt_line *l, u32 lo, u32 hi)
{
	u32 nlo = (u32)round_down(lo, r->bsize);
	u32 nhi = (u32)round_up(hi, r->bsize);
	u32 old = l->dhi - l->dlo;

	if (nhi > l->len)
		nhi = l->len;
	if (l->dhi > l->dlo) {
		if (l->dlo < nlo)
			nlo = l->dlo;
		if (l->dhi > nhi)
			nhi = l->dhi;
	}
	l->dlo = nlo;
	l->dhi = nhi;
	r->dirty_bytes += (u64)(nhi - nlo) - old;
	if (!r->first_dirty_ns)
		r->first_dirty_ns = now_ns();
}

static int line_writeback(struct xt_raw *r, struct xt_line *l)
{
	s64 off;

	if (l->dhi <= l->dlo)
		return 0;
	off = (l->idx << r->line_shift) + l->dlo;
	check_align(r, off, l->dhi - l->dlo);
	if (sys_pwrite_full(r->fd, l->data + l->dlo, l->dhi - l->dlo, off))
		return -1;
	r->st_flushed += l->dhi - l->dlo;
	mark_clean(r, l);
	return 0;
}

/* Get a free line structure, evicting the least recently used one. */
static struct xt_line *line_alloc(struct xt_raw *r)
{
	struct xt_line *l;

	if (r->nlines < r->nlines_max) {
		l = calloc(1, sizeof(*l));
		if (!l)
			goto evict;
		if (posix_memalign((void **)&l->data, XT_MEM_ALIGN,
				r->line_size)) {
			free(l);
			goto evict;
		}
		r->nlines++;
		return l;
	}
evict:
	l = r->lru_tail;
	if (!l) {
		errno = ENOMEM;
		return NULL;
	}
	if (line_writeback(r, l))
		return NULL;
	lru_unlink(r, l);
	hash_remove(r, l);
	return l;
}

static void line_discard(struct xt_raw *r, struct xt_line *l)
{
	/* Unused line structure: keep it in the LRU tail for reuse. */
	l->idx = -1;
	l->len = 0;
	l->dlo = l->dhi = 0;
	if (!l->prev && !l->next && r->lru_head != l) {
		/* not linked: append to the tail */
		l->prev = r->lru_tail;
		l->next = NULL;
		if (r->lru_tail)
			r->lru_tail->next = l;
		r->lru_tail = l;
		if (!r->lru_head)
			r->lru_head = l;
	}
}

/*
 * Return the cached line for @idx, loading it from the device when
 * @load is set. Returns NULL on error (errno set) or past the device end
 * (errno 0).
 */
static struct xt_line *line_get(struct xt_raw *r, s64 idx, int load)
{
	struct xt_line *l;
	u32 len;

	l = line_lookup(r, idx);
	if (l) {
		r->st_hits++;
		if (r->lru_head != l) {
			lru_unlink(r, l);
			lru_push_head(r, l);
		}
		return l;
	}
	len = line_len_for(r, idx);
	if (!len) {
		errno = 0;
		return NULL;
	}
	l = line_alloc(r);
	if (!l)
		return NULL;
	l->idx = idx;
	l->len = len;
	l->dlo = l->dhi = 0;
	if (load) {
		r->st_misses++;
		if (dev_read(r, l->data, len, idx << r->line_shift)) {
			int err = errno;
			line_discard(r, l);
			errno = err;
			return NULL;
		}
	}
	hash_insert(r, l);
	lru_push_head(r, l);
	return l;
}

static int cmp_line(const void *a, const void *b)
{
	const struct xt_line *x = *(struct xt_line * const *)a;
	const struct xt_line *y = *(struct xt_line * const *)b;

	return x->idx < y->idx ? -1 : x->idx > y->idx;
}

/* Write back every dirty line, in device order, coalescing neighbours. */
static int flush_all_locked(struct xt_raw *r)
{
	struct xt_line *l;
	u32 n = 0, i, j;
	int ret = 0;

	if (!r->dirty_bytes)
		return 0;
	for (l = r->lru_head; l; l = l->next)
		if (l->idx >= 0 && l->dhi > l->dlo)
			r->sortbuf[n++] = l;
	qsort(r->sortbuf, n, sizeof(*r->sortbuf), cmp_line);

	for (i = 0; i < n; i = j) {
		s64 run_off;
		u32 run_len = 0;

		l = r->sortbuf[i];
		run_off = (l->idx << r->line_shift) + l->dlo;
		j = i;
		/* Gather contiguous dirty ranges into the bounce buffer. */
		while (j < n) {
			struct xt_line *c = r->sortbuf[j];
			s64 c_off = (c->idx << r->line_shift) + c->dlo;
			u32 c_len = c->dhi - c->dlo;

			if (j > i && (c_off != run_off + run_len ||
					run_len + c_len > r->bounce_size))
				break;
			if (j == i && c_len > r->bounce_size)
				break;
			memcpy(r->bounce + run_len, c->data + c->dlo, c_len);
			run_len += c_len;
			j++;
		}
		if (j == i) {
			/* single range larger than the bounce buffer */
			if (line_writeback(r, l)) {
				ret = -1;
				r->io_error = errno;
				break;
			}
			j = i + 1;
			continue;
		}
		check_align(r, run_off, run_len);
		if (sys_pwrite_full(r->fd, r->bounce, run_len, run_off)) {
			ret = -1;
			r->io_error = errno;
			break;
		}
		r->st_flushed += run_len;
		for (; i < j; i++)
			mark_clean(r, r->sortbuf[i]);
	}
	if (!ret)
		r->io_error = 0;
	return ret;
}

/* ------------------------------------------------------------------ */
/* background flusher                                                 */
/* ------------------------------------------------------------------ */

static void *flusher_main(void *arg)
{
	struct xt_raw *r = arg;
	sigset_t all;
	pid_t me = getpid();

	sigfillset(&all);
	pthread_sigmask(SIG_BLOCK, &all, NULL);

	pthread_mutex_lock(&r->mtx);
	while (!r->closing && r->thr_pid == me) {
		struct timeval tv;
		struct timespec ts;
		u64 now;

		gettimeofday(&tv, NULL);
		ts.tv_sec = tv.tv_sec;
		ts.tv_nsec = (long)tv.tv_usec * 1000 + XT_TICK_MS * 1000000L;
		if (ts.tv_nsec >= 1000000000L) {
			ts.tv_sec += ts.tv_nsec / 1000000000L;
			ts.tv_nsec %= 1000000000L;
		}
		pthread_cond_timedwait(&r->cond, &r->mtx, &ts);
		if (r->closing || r->thr_pid != me)
			break;
		now = now_ns();
		if (r->dirty_bytes && r->first_dirty_ns &&
		    now - r->first_dirty_ns >= r->flush_ns &&
		    now >= r->retry_after_ns) {
			if (flush_all_locked(r))
				r->retry_after_ns = now + XT_RETRY_NS;
		}
	}
	pthread_mutex_unlock(&r->mtx);
	return NULL;
}

static void ensure_flusher(struct xt_raw *r)
{
	pid_t me;

	if (r->no_thread || r->closing)
		return;
	me = getpid();
	if (r->thr_running && r->thr_pid == me)
		return;
	r->thr_pid = me;
	if (pthread_create(&r->thr, NULL, flusher_main, r)) {
		ntfs_log_error("xt_rawio: no flusher thread, using "
			"write-through\n");
		r->no_thread = 1;
		r->thr_running = 0;
		return;
	}
	r->thr_running = 1;
}

/* ------------------------------------------------------------------ */
/* small (cached or sector-RMW) I/O                                   */
/* ------------------------------------------------------------------ */

static s64 edge_read(struct xt_raw *r, char *buf, s64 count, s64 off)
{
	s64 done = 0;

	while (count > 0) {
		s64 a0 = round_down(off, r->bsize);
		s64 a1 = round_up(off + count, r->bsize);
		s64 n;

		if (a1 - a0 > XT_EDGE_SIZE)
			a1 = a0 + XT_EDGE_SIZE;
		if (a1 > r->devsize)
			a1 = r->devsize;
		if (a1 <= off)
			break;
		if (dev_read(r, r->edge, a1 - a0, a0))
			return done ? done : -1;
		n = a1 - off;
		if (n > count)
			n = count;
		memcpy(buf, r->edge + (off - a0), (size_t)n);
		buf += n;
		off += n;
		count -= n;
		done += n;
	}
	return done;
}

static s64 edge_write(struct xt_raw *r, const char *buf, s64 count, s64 off)
{
	s64 done = 0;

	while (count > 0) {
		s64 a0 = round_down(off, r->bsize);
		s64 a1 = round_up(off + count, r->bsize);
		s64 n;

		if (a1 - a0 > XT_EDGE_SIZE)
			a1 = a0 + XT_EDGE_SIZE;
		if (a1 > r->devsize)
			a1 = r->devsize;
		if (a1 <= off)
			break;
		n = a1 - off;
		if (n > count)
			n = count;
		/* Only read when sectors are partially overwritten. */
		if (off != a0 || off + n != a1) {
			if (dev_read(r, r->edge, a1 - a0, a0))
				return done ? done : -1;
		}
		memcpy(r->edge + (off - a0), buf, (size_t)n);
		if (dev_write(r, r->edge, a1 - a0, a0))
			return done ? done : -1;
		buf += n;
		off += n;
		count -= n;
		done += n;
	}
	return done;
}

static s64 cached_read(struct xt_raw *r, char *buf, s64 count, s64 off)
{
	s64 done = 0;

	while (count > 0) {
		s64 idx = off >> r->line_shift;
		u32 lo = (u32)(off & (r->line_size - 1));
		struct xt_line *l = line_get(r, idx, 1);
		s64 n;

		if (!l) {
			if (done || !errno)
				break;
			return -1;
		}
		if (lo >= l->len)
			break;
		n = l->len - lo;
		if (n > count)
			n = count;
		memcpy(buf, l->data + lo, (size_t)n);
		buf += n;
		off += n;
		count -= n;
		done += n;
	}
	return done;
}

static s64 cached_write(struct xt_raw *r, const char *buf, s64 count, s64 off)
{
	s64 done = 0;

	while (count > 0) {
		s64 idx = off >> r->line_shift;
		u32 lo = (u32)(off & (r->line_size - 1));
		u32 len = line_len_for(r, idx);
		struct xt_line *l;
		s64 n;

		if (!len || lo >= len)
			break;
		n = len - lo;
		if (n > count)
			n = count;
		/* A full-line overwrite does not need the old contents. */
		l = line_get(r, idx, !(lo == 0 && n == len));
		if (!l) {
			if (done || !errno)
				break;
			return -1;
		}
		memcpy(l->data + lo, buf, (size_t)n);
		mark_dirty(r, l, lo, lo + (u32)n);
		buf += n;
		off += n;
		count -= n;
		done += n;
	}
	if (done) {
		if (r->dirty_bytes > r->dirty_max || r->no_thread) {
			if (flush_all_locked(r) && !r->no_thread)
				r->retry_after_ns = now_ns() + XT_RETRY_NS;
			if (r->no_thread && r->io_error) {
				errno = r->io_error;
				return -1;
			}
		}
		ensure_flusher(r);
	}
	return done;
}

static s64 small_read(struct xt_raw *r, char *buf, s64 count, s64 off)
{
	return r->nlines_max ? cached_read(r, buf, count, off)
			     : edge_read(r, buf, count, off);
}

static s64 small_write(struct xt_raw *r, const char *buf, s64 count, s64 off)
{
	return r->nlines_max ? cached_write(r, buf, count, off)
			     : edge_write(r, buf, count, off);
}

/* ------------------------------------------------------------------ */
/* large (direct) I/O                                                 */
/* ------------------------------------------------------------------ */

/* Copy newer cached data over a buffer just read from the device. */
static void overlay_dirty(struct xt_raw *r, char *buf, s64 len, s64 off)
{
	s64 first, last, idx;

	if (!r->dirty_bytes)
		return;
	first = off >> r->line_shift;
	last = (off + len - 1) >> r->line_shift;
	for (idx = first; idx <= last; idx++) {
		struct xt_line *l = line_lookup(r, idx);
		s64 ls, a, b;

		if (!l || l->dhi <= l->dlo)
			continue;
		ls = idx << r->line_shift;
		a = ls + l->dlo;
		b = ls + l->dhi;
		if (a < off)
			a = off;
		if (b > off + len)
			b = off + len;
		if (b > a)
			memcpy(buf + (a - off), l->data + (a - ls), (size_t)(b - a));
	}
}

/* Bring cached copies up to date after a direct write. */
static void update_cached(struct xt_raw *r, const char *buf, s64 len, s64 off)
{
	s64 first, last, idx;

	if (!r->nlines)
		return;
	first = off >> r->line_shift;
	last = (off + len - 1) >> r->line_shift;
	for (idx = first; idx <= last; idx++) {
		struct xt_line *l = line_lookup(r, idx);
		s64 ls, a, b;

		if (!l)
			continue;
		ls = idx << r->line_shift;
		a = ls > off ? ls : off;
		b = ls + l->len < off + len ? ls + l->len : off + len;
		if (b <= a)
			continue;
		memcpy(l->data + (a - ls), buf + (a - off), (size_t)(b - a));
		/* Dirty bytes now fully on the device? */
		if (l->dhi > l->dlo && a <= ls + l->dlo && b >= ls + l->dhi)
			mark_clean(r, l);
	}
}

static s64 direct_read(struct xt_raw *r, char *buf, s64 count, s64 off)
{
	s64 done = 0, mid, n;
	u32 head = (u32)(off & (r->bsize - 1));

	if (head) {
		n = r->bsize - head;
		if (n > count)
			n = count;
		n = small_read(r, buf, n, off);
		if (n <= 0)
			return n;
		done += n;
		if (done < count && ((off + done) & (r->bsize - 1)))
			return done;
	}
	mid = round_down(count - done, r->bsize);
	if (mid > 0) {
		if (dev_read(r, buf + done, mid, off + done))
			return done ? done : -1;
		overlay_dirty(r, buf + done, mid, off + done);
		r->st_direct += mid;
		done += mid;
	}
	if (done < count) {
		n = small_read(r, buf + done, count - done, off + done);
		if (n < 0)
			return done ? done : -1;
		done += n;
	}
	return done;
}

static s64 direct_write(struct xt_raw *r, const char *buf, s64 count, s64 off)
{
	s64 done = 0, mid, n;
	u32 head = (u32)(off & (r->bsize - 1));

	if (head) {
		n = r->bsize - head;
		if (n > count)
			n = count;
		n = small_write(r, buf, n, off);
		if (n <= 0)
			return n;
		done += n;
		if (done < count && ((off + done) & (r->bsize - 1)))
			return done;
	}
	mid = round_down(count - done, r->bsize);
	if (mid > 0) {
		if (dev_write(r, buf + done, mid, off + done))
			return done ? done : -1;
		update_cached(r, buf + done, mid, off + done);
		r->st_direct += mid;
		done += mid;
	}
	if (done < count) {
		n = small_write(r, buf + done, count - done, off + done);
		if (n < 0)
			return done ? done : -1;
		done += n;
	}
	return done;
}

/* ------------------------------------------------------------------ */
/* public API                                                         */
/* ------------------------------------------------------------------ */

int xt_raw_wanted(int fd)
{
	const char *e = getenv("XTNTFS_RAWIO");
	struct stat st;

	if (e && !strcmp(e, "0"))
		return 0;
	if (getenv("XTNTFS_SIMULATE_RAW"))
		return 1;
	if (fstat(fd, &st))
		return 0;
#if defined(__APPLE__) || defined(__DARWIN__)
	return S_ISCHR(st.st_mode);
#else
	(void)st;
	return 0;
#endif
}

int xt_raw_open_flags(void)
{
#if defined(__linux__) && defined(O_DIRECT)
	const char *e = getenv("XTNTFS_SIMULATE_ODIRECT");

	if (getenv("XTNTFS_SIMULATE_RAW") && e && !strcmp(e, "1"))
		return O_DIRECT;
#endif
	return 0;
}

static int query_geometry(struct xt_raw *r, u32 *bsize, s64 *size)
{
	struct stat st;

	*bsize = XT_MIN_SECTOR;
	*size = -1;
#if defined(__APPLE__) || defined(__DARWIN__)
	{
		uint32_t bs = 0;
		uint64_t cnt = 0;

		if (!ioctl(r->fd, DKIOCGETBLOCKSIZE, &bs) && bs)
			*bsize = bs;
		if (!ioctl(r->fd, DKIOCGETBLOCKCOUNT, &cnt) && cnt)
			*size = (s64)cnt * (s64)*bsize;
	}
#endif
#if defined(__linux__) && defined(BLKGETSIZE64)
	if (*size < 0) {
		uint64_t sz;

		if (!ioctl(r->fd, BLKGETSIZE64, &sz))
			*size = (s64)sz;
	}
#endif
	if (*size < 0) {
		if (fstat(r->fd, &st))
			return -1;
		*size = st.st_size;
	}
	return 0;
}

struct xt_raw *xt_raw_attach(int fd, int writable, const char *name)
{
	struct xt_raw *r;
	unsigned long v;
	u32 bsize;
	s64 size;
	u32 hsize;

	pthread_once(&xt_atfork_once, xt_atfork_install);

	r = calloc(1, sizeof(*r));
	if (!r)
		return NULL;
	r->fd = fd;
	r->writable = writable;
	r->simulate = getenv("XTNTFS_SIMULATE_RAW") != NULL;
	if (query_geometry(r, &bsize, &size))
		goto err;
	if (r->simulate) {
		v = env_ulong("XTNTFS_SIMULATE_RAW", XT_MIN_SECTOR);
		if (v >= XT_MIN_SECTOR && is_pow2(v))
			bsize = (u32)v;
	}
	if (bsize < XT_MIN_SECTOR || !is_pow2(bsize))
		bsize = XT_MIN_SECTOR;
	r->bsize = bsize;
	r->devsize = round_down(size, bsize);

	v = env_ulong("XTNTFS_LINE_KB", XT_DEF_LINE_KB) << 10;
	if (!is_pow2(v) || v < 4096 || v < bsize || v > (16ul << 20))
		v = XT_DEF_LINE_KB << 10;
	if (v < bsize)
		v = bsize;
	r->line_size = (u32)v;
	r->line_shift = ilog2_u32(r->line_size);

	v = env_ulong("XTNTFS_CACHE_MB", XT_DEF_CACHE_MB);
	if (v > 4096)
		v = 4096;
	r->nlines_max = (u32)((v << 20) / r->line_size);
	if (v && r->nlines_max < 8)
		r->nlines_max = 8;

	v = env_ulong("XTNTFS_DIRECT_KB", XT_DEF_DIRECT_KB) << 10;
	if (v < bsize)
		v = bsize;
	r->direct_min = (u32)v;

	v = env_ulong("XTNTFS_DIRTY_MB", XT_DEF_DIRTY_MB) << 20;
	if (r->nlines_max &&
	    v > (u64)r->nlines_max * r->line_size / 2)
		v = (u64)r->nlines_max * r->line_size / 2;
	if (v < r->line_size)
		v = r->line_size;
	r->dirty_max = v;

	r->flush_ns = (u64)env_ulong("XTNTFS_FLUSH_MS", XT_DEF_FLUSH_MS)
			* 1000000ull;

	r->bounce_size = XT_BOUNCE_MIN > r->line_size ? XT_BOUNCE_MIN
						      : r->line_size;
	if (posix_memalign((void **)&r->bounce, XT_MEM_ALIGN, r->bounce_size))
		goto err;
	if (posix_memalign((void **)&r->edge, XT_MEM_ALIGN,
			XT_EDGE_SIZE + 2 * bsize))
		goto err;

	hsize = 64;
	while (hsize < r->nlines_max * 2)
		hsize <<= 1;
	r->hmask = hsize - 1;
	r->hash = calloc(hsize, sizeof(*r->hash));
	if (!r->hash)
		goto err;
	if (r->nlines_max) {
		r->sortbuf = calloc(r->nlines_max, sizeof(*r->sortbuf));
		if (!r->sortbuf)
			goto err;
	}
	r->name = name ? strdup(name) : NULL;
	pthread_mutex_init(&r->mtx, NULL);
	pthread_cond_init(&r->cond, NULL);

	pthread_mutex_lock(&xt_reg_mtx);
	r->reg_next = xt_reg_head;
	xt_reg_head = r;
	pthread_mutex_unlock(&xt_reg_mtx);

	ntfs_log_debug("xt_rawio: %s sector=%u size=%lld line=%u cache=%u "
		"lines direct>=%u\n", name ? name : "?", r->bsize,
		(long long)r->devsize, r->line_size, r->nlines_max,
		r->direct_min);
	return r;
err:
	free(r->bounce);
	free(r->edge);
	free(r->hash);
	free(r->sortbuf);
	free(r);
	errno = ENOMEM;
	return NULL;
}

s64 xt_raw_pread(struct xt_raw *r, void *buf, s64 count, s64 offset)
{
	s64 ret;

	if (count < 0 || offset < 0) {
		errno = EINVAL;
		return -1;
	}
	pthread_mutex_lock(&r->mtx);
	if (offset >= r->devsize || !count) {
		ret = 0;
		goto out;
	}
	if (count > r->devsize - offset)
		count = r->devsize - offset;
	if (count >= (s64)r->direct_min)
		ret = direct_read(r, buf, count, offset);
	else
		ret = small_read(r, buf, count, offset);
out:
	pthread_mutex_unlock(&r->mtx);
	return ret;
}

s64 xt_raw_pwrite(struct xt_raw *r, const void *buf, s64 count, s64 offset)
{
	s64 ret;

	if (count < 0 || offset < 0) {
		errno = EINVAL;
		return -1;
	}
	if (!r->writable) {
		errno = EROFS;
		return -1;
	}
	pthread_mutex_lock(&r->mtx);
	if (!count) {
		ret = 0;
		goto out;
	}
	if (offset >= r->devsize) {
		errno = ENOSPC;
		ret = -1;
		goto out;
	}
	if (count > r->devsize - offset)
		count = r->devsize - offset;
	if (count >= (s64)r->direct_min)
		ret = direct_write(r, buf, count, offset);
	else
		ret = small_write(r, buf, count, offset);
out:
	pthread_mutex_unlock(&r->mtx);
	return ret;
}

s64 xt_raw_seek(struct xt_raw *r, s64 offset, int whence)
{
	s64 npos;

	pthread_mutex_lock(&r->mtx);
	switch (whence) {
	case SEEK_SET:
		npos = offset;
		break;
	case SEEK_CUR:
		npos = r->pos + offset;
		break;
	case SEEK_END:
		npos = r->devsize + offset;
		break;
	default:
		npos = -1;
	}
	if (npos < 0) {
		pthread_mutex_unlock(&r->mtx);
		errno = EINVAL;
		return -1;
	}
	r->pos = npos;
	pthread_mutex_unlock(&r->mtx);
	return npos;
}

s64 xt_raw_read(struct xt_raw *r, void *buf, s64 count)
{
	s64 n = xt_raw_pread(r, buf, count, r->pos);

	if (n > 0)
		r->pos += n;
	return n;
}

s64 xt_raw_write(struct xt_raw *r, const void *buf, s64 count)
{
	s64 n = xt_raw_pwrite(r, buf, count, r->pos);

	if (n > 0)
		r->pos += n;
	return n;
}

int xt_raw_flush(struct xt_raw *r)
{
	int ret;

	pthread_mutex_lock(&r->mtx);
	ret = flush_all_locked(r);
	if (ret)
		errno = r->io_error ? r->io_error : EIO;
	pthread_mutex_unlock(&r->mtx);
	return ret;
}

int xt_raw_detach(struct xt_raw *r)
{
	struct xt_raw **pp;
	struct xt_line *l, *next;
	int join, ret;

	pthread_mutex_lock(&r->mtx);
	r->closing = 1;
	join = r->thr_running && r->thr_pid == getpid();
	pthread_cond_broadcast(&r->cond);
	pthread_mutex_unlock(&r->mtx);
	if (join)
		pthread_join(r->thr, NULL);

	pthread_mutex_lock(&r->mtx);
	ret = flush_all_locked(r);
	if (ret)
		ntfs_log_error("xt_rawio: could not write back cached data "
			"for %s: %s\n", r->name ? r->name : "device",
			strerror(r->io_error));
	pthread_mutex_unlock(&r->mtx);

	if (getenv("XTNTFS_STATS"))
		fprintf(stderr, "xt_rawio stats: hits=%llu misses=%llu "
			"direct=%llu flushed=%llu\n",
			(unsigned long long)r->st_hits,
			(unsigned long long)r->st_misses,
			(unsigned long long)r->st_direct,
			(unsigned long long)r->st_flushed);

	pthread_mutex_lock(&xt_reg_mtx);
	for (pp = &xt_reg_head; *pp; pp = &(*pp)->reg_next)
		if (*pp == r) {
			*pp = r->reg_next;
			break;
		}
	pthread_mutex_unlock(&xt_reg_mtx);

	for (l = r->lru_head; l; l = next) {
		next = l->next;
		free(l->data);
		free(l);
	}
	pthread_mutex_destroy(&r->mtx);
	pthread_cond_destroy(&r->cond);
	free(r->bounce);
	free(r->edge);
	free(r->hash);
	free(r->sortbuf);
	free(r->name);
	free(r);
	return ret;
}

void xt_raw_stats(struct xt_raw *r, u64 *hits, u64 *misses,
		u64 *direct_bytes, u64 *flushed_bytes)
{
	pthread_mutex_lock(&r->mtx);
	if (hits)
		*hits = r->st_hits;
	if (misses)
		*misses = r->st_misses;
	if (direct_bytes)
		*direct_bytes = r->st_direct;
	if (flushed_bytes)
		*flushed_bytes = r->st_flushed;
	pthread_mutex_unlock(&r->mtx);
}
