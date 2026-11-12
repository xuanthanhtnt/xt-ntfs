/*
 * xt_names.h - XT NTFS: Mac file names on volumes mounted with windows_names.
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
 * Mac file names may hold characters that Windows does not allow, and
 * windows_names refused them: Finder then stopped copying any folder that
 * held one, such as the custom folder icon file "Icon\r" or a date typed
 * as 12/11 (which Finder stores as "12:11"). Like the macOS SMB client and
 * Samba, these characters are stored as Unicode private-use characters and
 * turned back when names are listed:
 *
 *	0x01-0x1f			U+F001-U+F01F
 *	"  *  :  <  >  ?  \  |		U+F020-U+F027
 *	trailing space, trailing period	U+F028, U+F029
 *
 * xt_names_wrap() wraps ntfs-3g's operations: paths are mapped on the way
 * in and directory entries on the way out. A name stored as is (by another
 * driver, or without windows_names) is still found. Extended attribute
 * names and symlink targets are not file names and are not mapped.
 *
 * Included by ntfs-3g.c just before its operations table, so it sees the
 * same FUSE declarations. macOS only (it uses macFUSE's operations).
 */

#if defined(__APPLE__) || defined(__DARWIN__)

static struct fuse_operations xt_names_next;	/* ntfs-3g's operations */

static const char xt_names_set[] = "\"*:<>?\\|";

/* Private-use code (0x01-0x29, as U+F000 + code) for byte c, or 0. */
static int xt_names_code(unsigned char c, int last)
{
	const char *s;

	if (c >= 0x01 && c <= 0x1f)
		return c;
	if (c && (s = strchr(xt_names_set, c)))
		return 0x20 + (int)(s - xt_names_set);
	if (last && c == ' ')
		return 0x28;
	if (last && c == '.')
		return 0x29;
	return 0;
}

/* The path with each component mapped (malloc'd), or NULL. */
static char *xt_names_encode(const char *path)
{
	char *out = malloc(strlen(path) * 3 + 1);
	char *o = out;
	const char *p = path, *end, *q;
	int dots, code;

	if (!out)
		return NULL;
	while (*p) {
		if (*p == '/') {
			*o++ = *p++;
			continue;
		}
		end = strchr(p, '/');
		if (!end)
			end = p + strlen(p);
		dots = (end - p == 1 && p[0] == '.')
			|| (end - p == 2 && p[0] == '.' && p[1] == '.');
		for (q = p; q < end; q++) {
			code = dots ? 0 : xt_names_code(*q, q + 1 == end);
			if (code) {
				/* UTF-8 of U+F000 + code (code < 0x40) */
				*o++ = (char)0xef;
				*o++ = (char)0x80;
				*o++ = (char)(0x80 | code);
			} else
				*o++ = *q;
		}
		p = end;
	}
	*o = '\0';
	return out;
}

/* A directory entry with the private-use characters turned back (malloc'd). */
static char *xt_names_decode(const char *name)
{
	char *out = malloc(strlen(name) + 1);
	char *o = out;
	const unsigned char *p = (const unsigned char *)name;
	int code;

	if (!out)
		return NULL;
	while (*p) {
		if (p[0] == 0xef && p[1] == 0x80 && p[2] >= 0x81 && p[2] <= 0xa9) {
			code = p[2] & 0x3f;
			if (code < 0x20)
				*o++ = (char)code;
			else if (code < 0x28)
				*o++ = xt_names_set[code - 0x20];
			else if (!p[3])
				*o++ = code == 0x28 ? ' ' : '.';
			else
				code = 0;	/* only mapped when trailing */
			if (code) {
				p += 3;
				continue;
			}
		}
		*o++ = (char)*p++;
	}
	*o = '\0';
	return out;
}

/*
 * Runs call with p set to the mapped path. For an existing name (retry),
 * it is run again with the path as given when the mapped name is not there.
 */
#define XT_NAMES_CALL(path, retry, call)				\
	do {								\
		char *xt_mapped = xt_names_encode(path);		\
		const char *p = xt_mapped;				\
		int xt_res;						\
									\
		if (!xt_mapped)						\
			return -ENOMEM;					\
		xt_res = (call);					\
		if ((retry) && xt_res == -ENOENT			\
		    && strcmp(xt_mapped, path)) {			\
			p = path;					\
			xt_res = (call);				\
		}							\
		free(xt_mapped);					\
		return xt_res;						\
	} while (0)
#define XT_NAMES_EXISTING(path, call)	XT_NAMES_CALL(path, 1, call)
#define XT_NAMES_NEW(path, call)	XT_NAMES_CALL(path, 0, call)

/* rename and link: an existing name and a new one. */
static int xt_names_two(int (*op)(const char *, const char *),
		const char *from, const char *to)
{
	char *f = xt_names_encode(from);
	char *t = xt_names_encode(to);
	int res = -ENOMEM;

	if (f && t) {
		res = op(f, t);
		if (res == -ENOENT && strcmp(f, from))
			res = op(from, t);
	}
	free(f);
	free(t);
	return res;
}

struct xt_names_dir {
	void *buf;
	fuse_fill_dir_t filler;
};

static int xt_names_fill(void *buf, const char *name,
		const struct stat *st, off_t off)
{
	struct xt_names_dir *dir = buf;
	char *decoded = xt_names_decode(name);
	int res;

	if (!decoded)
		return 1;	/* stop the listing */
	res = dir->filler(dir->buf, decoded, st, off);
	free(decoded);
	return res;
}

static int xt_names_getattr(const char *path, struct stat *st)
{
	XT_NAMES_EXISTING(path, xt_names_next.getattr(p, st));
}

static int xt_names_readlink(const char *path, char *buf, size_t size)
{
	XT_NAMES_EXISTING(path, xt_names_next.readlink(p, buf, size));
}

static int xt_names_readdir(const char *path, void *buf,
		fuse_fill_dir_t filler, off_t off, struct fuse_file_info *fi)
{
	struct xt_names_dir dir = { buf, filler };

	XT_NAMES_EXISTING(path,
		xt_names_next.readdir(p, &dir, xt_names_fill, off, fi));
}

static int xt_names_open(const char *path, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.open(p, fi));
}

static int xt_names_release(const char *path, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.release(p, fi));
}

static int xt_names_read(const char *path, char *buf, size_t size,
		off_t off, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.read(p, buf, size, off, fi));
}

static int xt_names_write(const char *path, const char *buf, size_t size,
		off_t off, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.write(p, buf, size, off, fi));
}

static int xt_names_truncate(const char *path, off_t size)
{
	XT_NAMES_EXISTING(path, xt_names_next.truncate(p, size));
}

static int xt_names_ftruncate(const char *path, off_t size,
		struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.ftruncate(p, size, fi));
}

static int xt_names_statfs(const char *path, struct statvfs *sfs)
{
	XT_NAMES_EXISTING(path, xt_names_next.statfs(p, sfs));
}

static int xt_names_chmod(const char *path, mode_t mode)
{
	XT_NAMES_EXISTING(path, xt_names_next.chmod(p, mode));
}

static int xt_names_chown(const char *path, uid_t uid, gid_t gid)
{
	XT_NAMES_EXISTING(path, xt_names_next.chown(p, uid, gid));
}

static int xt_names_create(const char *path, mode_t mode,
		struct fuse_file_info *fi)
{
	XT_NAMES_NEW(path, xt_names_next.create(p, mode, fi));
}

static int xt_names_mknod(const char *path, mode_t mode, dev_t dev)
{
	XT_NAMES_NEW(path, xt_names_next.mknod(p, mode, dev));
}

static int xt_names_symlink(const char *target, const char *path)
{
	XT_NAMES_NEW(path, xt_names_next.symlink(target, p));
}

static int xt_names_link(const char *from, const char *to)
{
	return xt_names_two(xt_names_next.link, from, to);
}

static int xt_names_unlink(const char *path)
{
	XT_NAMES_EXISTING(path, xt_names_next.unlink(p));
}

static int xt_names_rename(const char *from, const char *to)
{
	return xt_names_two(xt_names_next.rename, from, to);
}

static int xt_names_mkdir(const char *path, mode_t mode)
{
	XT_NAMES_NEW(path, xt_names_next.mkdir(p, mode));
}

static int xt_names_rmdir(const char *path)
{
	XT_NAMES_EXISTING(path, xt_names_next.rmdir(p));
}

static int xt_names_utimens(const char *path, const struct timespec tv[2])
{
	XT_NAMES_EXISTING(path, xt_names_next.utimens(p, tv));
}

static int xt_names_utime(const char *path, struct utimbuf *buf)
{
	XT_NAMES_EXISTING(path, xt_names_next.utime(p, buf));
}

static int xt_names_fsync(const char *path, int type,
		struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.fsync(p, type, fi));
}

static int xt_names_fsyncdir(const char *path, int type,
		struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.fsyncdir(p, type, fi));
}

static int xt_names_bmap(const char *path, size_t blocksize, uint64_t *idx)
{
	XT_NAMES_EXISTING(path, xt_names_next.bmap(p, blocksize, idx));
}

static int xt_names_ioctl(const char *path, int cmd, void *arg,
		struct fuse_file_info *fi, unsigned int flags, void *data)
{
	XT_NAMES_EXISTING(path,
		xt_names_next.ioctl(p, cmd, arg, fi, flags, data));
}

static int xt_names_access(const char *path, int type)
{
	XT_NAMES_EXISTING(path, xt_names_next.access(p, type));
}

static int xt_names_opendir(const char *path, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.opendir(p, fi));
}

static int xt_names_releasedir(const char *path, struct fuse_file_info *fi)
{
	XT_NAMES_EXISTING(path, xt_names_next.releasedir(p, fi));
}

static int xt_names_getxattr(const char *path, const char *name,
		char *value, size_t size, uint32_t position)
{
	XT_NAMES_EXISTING(path,
		xt_names_next.getxattr(p, name, value, size, position));
}

static int xt_names_setxattr(const char *path, const char *name,
		const char *value, size_t size, int flags, uint32_t position)
{
	XT_NAMES_EXISTING(path,
		xt_names_next.setxattr(p, name, value, size, flags, position));
}

static int xt_names_listxattr(const char *path, char *list, size_t size)
{
	XT_NAMES_EXISTING(path, xt_names_next.listxattr(p, list, size));
}

static int xt_names_removexattr(const char *path, const char *name)
{
	XT_NAMES_EXISTING(path, xt_names_next.removexattr(p, name));
}

static int xt_names_getxtimes(const char *path, struct timespec *bkuptime,
		struct timespec *crtime)
{
	XT_NAMES_EXISTING(path,
		xt_names_next.getxtimes(p, bkuptime, crtime));
}

static int xt_names_setcrtime(const char *path, const struct timespec *tv)
{
	XT_NAMES_EXISTING(path, xt_names_next.setcrtime(p, tv));
}

static int xt_names_setbkuptime(const char *path, const struct timespec *tv)
{
	XT_NAMES_EXISTING(path, xt_names_next.setbkuptime(p, tv));
}

static int xt_names_setchgtime(const char *path, const struct timespec *tv)
{
	XT_NAMES_EXISTING(path, xt_names_next.setchgtime(p, tv));
}

#define XT_NAMES_WRAP(op)	do { if (ops->op) ops->op = xt_names_##op; } while (0)

/*
 * Maps names for every operation ntfs-3g provides. If it provides one that
 * takes a path and has no wrapper here, names are left as they are (plain
 * windows_names) rather than mapped for some operations only.
 */
static void xt_names_wrap(struct fuse_operations *ops)
{
	if (ops->getdir || ops->flush || ops->fgetattr || ops->lock
	    || ops->poll || ops->write_buf || ops->read_buf || ops->flock
	    || ops->fallocate || ops->monitor || ops->renamex
	    || ops->statfs_x || ops->exchange || ops->chflags
	    || ops->setattr_x || ops->fsetattr_x) {
		ntfs_log_error("XT NTFS: file names are not mapped (unhandled operation)\n");
		return;
	}
	xt_names_next = *ops;
	XT_NAMES_WRAP(getattr);
	XT_NAMES_WRAP(readlink);
	XT_NAMES_WRAP(readdir);
	XT_NAMES_WRAP(open);
	XT_NAMES_WRAP(release);
	XT_NAMES_WRAP(read);
	XT_NAMES_WRAP(write);
	XT_NAMES_WRAP(truncate);
	XT_NAMES_WRAP(ftruncate);
	XT_NAMES_WRAP(statfs);
	XT_NAMES_WRAP(chmod);
	XT_NAMES_WRAP(chown);
	XT_NAMES_WRAP(create);
	XT_NAMES_WRAP(mknod);
	XT_NAMES_WRAP(symlink);
	XT_NAMES_WRAP(link);
	XT_NAMES_WRAP(unlink);
	XT_NAMES_WRAP(rename);
	XT_NAMES_WRAP(mkdir);
	XT_NAMES_WRAP(rmdir);
	XT_NAMES_WRAP(utimens);
	XT_NAMES_WRAP(utime);
	XT_NAMES_WRAP(fsync);
	XT_NAMES_WRAP(fsyncdir);
	XT_NAMES_WRAP(bmap);
	XT_NAMES_WRAP(ioctl);
	XT_NAMES_WRAP(access);
	XT_NAMES_WRAP(opendir);
	XT_NAMES_WRAP(releasedir);
	XT_NAMES_WRAP(getxattr);
	XT_NAMES_WRAP(setxattr);
	XT_NAMES_WRAP(listxattr);
	XT_NAMES_WRAP(removexattr);
	XT_NAMES_WRAP(getxtimes);
	XT_NAMES_WRAP(setcrtime);
	XT_NAMES_WRAP(setbkuptime);
	XT_NAMES_WRAP(setchgtime);
}

#endif /* defined(__APPLE__) || defined(__DARWIN__) */
