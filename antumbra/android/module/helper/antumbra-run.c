/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * antumbra-run: start a program as an unprivileged user with no
 * capabilities. The Antumbra module uses it to start tor (uid 2950) and the
 * DNS filter (uid 2951), and to talk to tor's control socket as uid 2950.
 *
 * Usage: antumbra-run -u UID -g GID [-G GID[,GID]...] [-d DIR] [-s]
 *                     [-e NAME=VALUE]... -- PROGRAM [ARG]...
 *
 *   -u UID   user ID to switch to (1-2147483647)
 *   -g GID   primary group ID (1-2147483647)
 *   -G LIST  supplementary group IDs, separated by commas (at most 16)
 *   -d DIR   working directory after the switch (default "/")
 *   -s       start a new session (setsid), detached from the caller's
 *   -e N=V   add N=V to the environment; the program gets no other
 *            environment except PATH=/system/bin (which -e PATH=... replaces)
 *
 * It must be started as root. Before running PROGRAM it:
 *   1. locks the securebits so that uid 0 never regains capabilities and
 *      the setuid capability fix-up cannot be switched off;
 *   2. empties the capability bounding set and the ambient set;
 *   3. sets the supplementary groups, then the real, effective and saved
 *      group and user IDs;
 *   4. clears the permitted, effective and inheritable capability sets and
 *      checks that all of them are empty and that setuid(0) fails;
 *   5. sets no_new_privs, so no later exec can gain privileges;
 *   6. closes every file descriptor above 2, resets signal dispositions
 *      and the signal mask, and changes directory.
 * Any failure stops it with exit status 125 before PROGRAM runs, so the
 * program never runs with more privilege than asked for. If PROGRAM cannot
 * be executed the exit status is 126 (or 127 if it does not exist).
 *
 * The module needs this helper because neither Android's toybox nor the
 * CI emulator has setpriv or setuidgid, and Magisk's su exists only under
 * Magisk (and since v30.7 keeps every capability unless --drop-cap is
 * given). One small program does the same thing everywhere and can be
 * tested on a Linux host.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <linux/capability.h>
#include <linux/securebits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_CLEAR_ALL
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif
#ifndef SECBIT_NO_CAP_AMBIENT_RAISE
#define SECBIT_NO_CAP_AMBIENT_RAISE (1 << 6)
#define SECBIT_NO_CAP_AMBIENT_RAISE_LOCKED (1 << 7)
#endif

#define EXIT_SETUP 125
#define MAX_GROUPS 16
#define MAX_ENV 32

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

static void die(const char *fmt, ...)
{
	va_list ap;
	int saved = errno;

	fputs("antumbra-run: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	if (saved)
		fprintf(stderr, ": %s", strerror(saved));
	fputc('\n', stderr);
	exit(EXIT_SETUP);
}

static void usage(void) __attribute__((noreturn));

static void usage(void)
{
	fputs("usage: antumbra-run -u UID -g GID [-G GID[,GID]...] [-d DIR] [-s]\n"
	      "                    [-e NAME=VALUE]... -- PROGRAM [ARG]...\n",
	      stderr);
	exit(EXIT_SETUP);
}

/* A decimal ID from 1 to INT_MAX, with no sign, spaces or leading zero. */
static unsigned long parse_id(const char *s, const char *what)
{
	unsigned long v = 0;
	const char *p;

	if (*s < '1' || *s > '9') {
		errno = 0;
		die("%s '%s' is not a positive decimal number", what, s);
	}
	for (p = s; *p; p++) {
		if (*p < '0' || *p > '9' || v > (unsigned long)INT_MAX / 10) {
			errno = 0;
			die("%s '%s' is not a number from 1 to %d", what, s, INT_MAX);
		}
		v = v * 10 + (unsigned long)(*p - '0');
	}
	if (v > (unsigned long)INT_MAX) {
		errno = 0;
		die("%s '%s' is larger than %d", what, s, INT_MAX);
	}
	return v;
}

static size_t parse_groups(char *list, gid_t *out)
{
	size_t n = 0;
	char *save = NULL;
	char *tok;

	for (tok = strtok_r(list, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
		if (n == MAX_GROUPS) {
			errno = 0;
			die("more than %d supplementary groups", MAX_GROUPS);
		}
		out[n++] = (gid_t)parse_id(tok, "group");
	}
	return n;
}

static int cap_last(void)
{
	char buf[16];
	ssize_t r;
	int fd = open("/proc/sys/kernel/cap_last_cap", O_RDONLY | O_CLOEXEC);
	int v = 63;

	if (fd >= 0) {
		r = read(fd, buf, sizeof(buf) - 1);
		if (r > 0) {
			buf[r] = '\0';
			v = atoi(buf);
			if (v < 0 || v > 63)
				v = 63;
		}
		close(fd);
	}
	return v;
}

static void caps_get(struct __user_cap_data_struct d[2])
{
	struct __user_cap_header_struct h = { _LINUX_CAPABILITY_VERSION_3, 0 };

	memset(d, 0, 2 * sizeof(*d));
	if (syscall(SYS_capget, &h, d) != 0)
		die("capget");
}

static void caps_clear(void)
{
	struct __user_cap_header_struct h = { _LINUX_CAPABILITY_VERSION_3, 0 };
	struct __user_cap_data_struct d[2];

	memset(d, 0, sizeof(d));
	if (syscall(SYS_capset, &h, d) != 0)
		die("capset");
}

/* Close every descriptor above 2. /proc/self/fd is read first, so the
 * directory's own descriptor is not closed while it is in use. */
static void close_fds(void)
{
	int fds[1024];
	size_t n = 0, i;
	DIR *d = opendir("/proc/self/fd");
	struct dirent *e;
	long max;
	int fd;

	if (d) {
		int dfd = dirfd(d);

		while ((e = readdir(d)) != NULL) {
			if (e->d_name[0] < '0' || e->d_name[0] > '9')
				continue;
			fd = atoi(e->d_name);
			if (fd > 2 && fd != dfd && n < sizeof(fds) / sizeof(fds[0]))
				fds[n++] = fd;
		}
		closedir(d);
		if (n < sizeof(fds) / sizeof(fds[0])) {
			for (i = 0; i < n; i++)
				close(fds[i]);
			return;
		}
	}
	/* No /proc, or too many descriptors to list: close them all. */
	max = sysconf(_SC_OPEN_MAX);
	if (max < 0 || max > 65536)
		max = 65536;
	for (fd = 3; fd < max; fd++)
		close(fd);
}

static void reset_signals(void)
{
	struct sigaction sa;
	sigset_t all;
	int s;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_DFL;
	for (s = 1; s < NSIG; s++) {
		if (s == SIGKILL || s == SIGSTOP)
			continue;
		sigaction(s, &sa, NULL); /* fails harmlessly for reserved signals */
	}
	sigemptyset(&all);
	if (sigprocmask(SIG_SETMASK, &all, NULL) != 0)
		die("sigprocmask");
}

int main(int argc, char **argv)
{
	unsigned long uid = 0, gid = 0;
	gid_t groups[MAX_GROUPS];
	size_t ngroups = 0;
	const char *dir = "/";
	int new_session = 0;
	char *env[MAX_ENV + 2];
	size_t nenv = 0;
	int have_path = 0;
	int opt, c, last, i;
	uid_t ru, eu, su;
	gid_t rg, eg, sg;
	gid_t check[MAX_GROUPS + 1];
	struct __user_cap_data_struct d[2];

	while ((opt = getopt(argc, argv, "+u:g:G:d:se:")) != -1) {
		switch (opt) {
		case 'u':
			uid = parse_id(optarg, "user");
			break;
		case 'g':
			gid = parse_id(optarg, "group");
			break;
		case 'G':
			ngroups = parse_groups(optarg, groups);
			break;
		case 'd':
			dir = optarg;
			break;
		case 's':
			new_session = 1;
			break;
		case 'e':
			if (!strchr(optarg, '=') || optarg[0] == '=') {
				errno = 0;
				die("-e needs NAME=VALUE, not '%s'", optarg);
			}
			if (nenv == MAX_ENV) {
				errno = 0;
				die("more than %d -e entries", MAX_ENV);
			}
			if (strncmp(optarg, "PATH=", 5) == 0)
				have_path = 1;
			env[nenv++] = optarg;
			break;
		default:
			usage();
		}
	}
	if (uid == 0 || gid == 0 || optind >= argc)
		usage();
	if (!have_path)
		env[nenv++] = "PATH=/system/bin";
	env[nenv] = NULL;

	errno = 0;
	if (geteuid() != 0)
		die("must be started as root");

	/* 1. Securebits: uid 0 gets no capabilities from now on, the setuid
	 * fix-up (which clears capabilities on the switch below) stays on,
	 * capabilities are not kept across setuid, and no ambient capability
	 * can be raised. Every bit is locked. */
	if (prctl(PR_SET_SECUREBITS,
		  SECBIT_NOROOT | SECBIT_NOROOT_LOCKED |
		  SECBIT_NO_SETUID_FIXUP_LOCKED |
		  SECBIT_KEEP_CAPS_LOCKED |
		  SECBIT_NO_CAP_AMBIENT_RAISE | SECBIT_NO_CAP_AMBIENT_RAISE_LOCKED,
		  0, 0, 0) != 0)
		die("cannot lock securebits");

	/* 2. Empty the bounding set, so nothing executed later can gain a
	 * capability from a file, and the ambient set. */
	last = cap_last();
	for (c = 0; c <= last; c++) {
		if (prctl(PR_CAPBSET_DROP, c, 0, 0, 0) != 0 && errno != EINVAL)
			die("cannot drop capability %d from the bounding set", c);
	}
	if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 && errno != EINVAL)
		die("cannot clear the ambient capabilities");

	/* 3. Groups first, while CAP_SETGID is still there. */
	if (setgroups(ngroups, ngroups ? groups : NULL) != 0)
		die("setgroups");
	if (setresgid((gid_t)gid, (gid_t)gid, (gid_t)gid) != 0)
		die("setresgid %lu", gid);
	if (setresuid((uid_t)uid, (uid_t)uid, (uid_t)uid) != 0)
		die("setresuid %lu", uid);

	/* 4. The switch away from uid 0 has already emptied the permitted and
	 * effective sets; clear all three explicitly and check. */
	caps_clear();
	caps_get(d);
	for (i = 0; i < 2; i++) {
		if (d[i].effective || d[i].permitted || d[i].inheritable) {
			errno = 0;
			die("capabilities are still set after the switch");
		}
	}
	for (c = 0; c <= last; c++) {
		if (prctl(PR_CAPBSET_READ, c, 0, 0, 0) == 1) {
			errno = 0;
			die("capability %d is still in the bounding set", c);
		}
	}
	if (getresuid(&ru, &eu, &su) != 0 || ru != uid || eu != uid || su != uid) {
		errno = 0;
		die("user IDs are not all %lu", uid);
	}
	if (getresgid(&rg, &eg, &sg) != 0 || rg != gid || eg != gid || sg != gid) {
		errno = 0;
		die("group IDs are not all %lu", gid);
	}
	if (getgroups(MAX_GROUPS + 1, check) != (int)ngroups) {
		errno = 0;
		die("supplementary groups were not set");
	}
	if (setuid(0) == 0 || setgid(0) == 0) {
		errno = 0;
		die("could switch back to uid or gid 0");
	}

	/* 5. No exec from here on can add privileges. */
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
		die("cannot set no_new_privs");

	/* 6. A clean process. */
	if (new_session && setsid() < 0)
		die("setsid");
	if (chdir(dir) != 0)
		die("cannot change directory to %s", dir);
	close_fds();
	reset_signals();

	execve(argv[optind], &argv[optind], env);
	c = errno;
	fprintf(stderr, "antumbra-run: cannot run %s: %s\n", argv[optind], strerror(c));
	return c == ENOENT ? 127 : 126;
}
