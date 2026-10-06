# SPDX-License-Identifier: GPL-3.0-or-later
"""antumbra-apply-welcome-settings, run for real as root in a private mount
namespace (needs root: in CI under sudo; skipped otherwise).

Inside the namespace /etc, /usr and /var are overlays of the host's (writes
land in a tmpfs), /run and /home are empty tmpfs mounts, and the image's
users exist. The greeter's files are written by the Welcome screen's own
settings module, owned by the greeter user. antumbra-persistence is the
real script, its partition and device-mapper paths moved into /run/test;
below it, stand-ins for the LUKS layer: cryptsetup (the volume is a
directory, its passphrase a file, an open mapping a file), mkfs.ext4, and
mount for the mapping (a bind of the directory). Stand-ins too: the
network unblock, systemctl and logger. chpasswd, passwd, install and stat
are the host's.

ANTUMBRA_TEST_APPLIER=PATH runs another copy of the applier, and
ANTUMBRA_TEST_PERSISTENCE=PATH another antumbra-persistence (to show what
an older one does).
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OVERLAY = os.path.join(ROOT, "config", "rootfs")
APPLIER = os.environ.get("ANTUMBRA_TEST_APPLIER") or os.path.join(OVERLAY, "usr", "local", "lib", "antumbra-apply-welcome-settings")
PERSISTENCE = os.environ.get("ANTUMBRA_TEST_PERSISTENCE") or os.path.join(OVERLAY, "usr", "local", "sbin", "antumbra-persistence")
FEATURES = os.path.join(OVERLAY, "etc", "antumbra", "persistence-features.conf")
HOOK56 = os.path.join(ROOT, "config", "hooks", "56-session-android.sh")
sys.path.insert(0, os.path.join(OVERLAY, "usr", "lib", "python3", "dist-packages"))

SETTINGS = "/var/lib/antumbra/settings"
MNT = "/var/lib/antumbra/persistence"
SECRET = "/etc/antumbra-test-root-only"
SECRET_TEXT = "root-only secret\n"
USERS = {"amnesia": 61910, "antumbra-greeter": 61911}

# antumbra-persistence: the real script (antumbra-persistence.real), each
# call logged.
PERSISTENCE_LOGGER = r"""#!/bin/sh
echo "$*" >> /run/test/persistence.log
exec /usr/local/lib/antumbra-persistence.real "$@"
"""
# Where the real script's partition and device-mapper paths are moved.
PART_LINE = ("PART=/dev/disk/by-partlabel/ANTUMBRA_DATA", "PART=/run/test/ANTUMBRA_DATA")
MAPPER_DIR = ("/dev/mapper/", "/run/test/mapper/")
MAPPING = "/run/test/mapper/antumbra_data"
# The LUKS layer below it. The volume's file system is the directory VOL,
# its passphrase the file VOL.key; an open mapping is a file in
# /run/test/mapper, which cannot be closed while its file system is still
# mounted (on the volume's mount point or a feature's).
CRYPTSETUP_STUB = r"""#!/bin/sh
set -eu
VOL=@VOL@
echo "$*" >> /run/test/cryptsetup.log
action="$1"
shift
key="" test="" args=""
while [ $# -gt 0 ]; do
    case "$1" in
        --key-file) key="$2"; shift ;;
        --test-passphrase) test=1 ;;
        --batch-mode) ;;
        --type|--label|--pbkdf|--pbkdf-memory|--pbkdf-force-iterations) shift ;;
        -*) echo "cryptsetup (test): unknown option $1" >&2; exit 2 ;;
        *) args="${args} $1" ;;
    esac
    shift
done
set -- ${args}
case "${action}" in
    isLuks) [ -f "${VOL}.key" ] ;;
    luksFormat) cat "${key}" > "${VOL}.key" ;;
    open)
        if [ ! -f "${VOL}.key" ] || ! cmp -s "${key}" "${VOL}.key"; then
            echo "No key available with this passphrase." >&2; exit 2
        fi
        [ -z "${test}" ] || exit 0
        if [ -e "/run/test/mapper/$2" ]; then echo "Device $2 already exists." >&2; exit 5; fi
        mkdir -p /run/test/mapper; : > "/run/test/mapper/$2" ;;
    close)
        while IFS='|' read -r name src dest rest; do
            case "${name}" in ''|'#'*) continue ;; esac
            if mountpoint -q "${dest}"; then echo "Device $1 is still in use." >&2; exit 5; fi
        done < /etc/antumbra/persistence-features.conf
        if mountpoint -q /var/lib/antumbra/persistence; then echo "Device $1 is still in use." >&2; exit 5; fi
        rm "/run/test/mapper/$1" ;;
    *) echo "cryptsetup (test): unexpected ${action}" >&2; exit 2 ;;
esac
"""
# A new file system on the open mapping: VOL emptied.
MKFS_STUB = r"""#!/bin/sh
set -eu
for last in "$@"; do :; done
[ "${last}" = @MAPPING@ ] && [ -e "${last}" ] || { echo "mkfs.ext4 (test): no device ${last}" >&2; exit 1; }
rm -rf @VOL@
mkdir @VOL@
"""
# Mounting the open mapping binds VOL; anything else is the real mount.
MOUNT_STUB = r"""#!/bin/sh
for last in "$@"; do :; done
case " $* " in
    *" @MAPPING@ "*)
        [ -e @MAPPING@ ] || { echo "mount (test): @MAPPING@ does not exist" >&2; exit 32; }
        exec @MOUNT@ --bind @VOL@ "${last}" ;;
esac
exec @MOUNT@ "$@"
"""
# umount: while /run/test/settings-busy exists, the Welcome settings'
# mount point is busy (only a lazy unmount takes it off).
UMOUNT_STUB = r"""#!/bin/sh
if [ -e /run/test/settings-busy ]; then
    case " $* " in
        *" -l "*) ;;
        *" /var/lib/antumbra/settings/persistent "*) echo "umount: /var/lib/antumbra/settings/persistent: target is busy." >&2; exit 32 ;;
    esac
fi
exec @UMOUNT@ "$@"
"""
RECORDER = """#!/bin/sh
echo "$*" >> /run/test/{name}.log
"""
# The greeter user winning a race (an LD_PRELOAD shim for the applier and
# everything it runs): just before root changes the mode or owner of a path
# in a directory the greeter user owns, the greeter renames a link to
# ANTUMBRA_RACE_TARGET over that path, as it can at any moment. Each swap is
# logged to /run/test/race.log.
RACE_SHIM = r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void greeter_wins(int dirfd, const char *path)
{
    const char *target = getenv("ANTUMBRA_RACE_TARGET"), *uid = getenv("ANTUMBRA_RACE_UID");
    char full[PATH_MAX], dir[PATH_MAX], link[PATH_MAX + 32];
    struct stat st;
    char *slash;
    FILE *log;

    if (!target || !uid || !path || !path[0])
        return;
    if (path[0] == '/' || dirfd == AT_FDCWD)
        snprintf(full, sizeof full, "%s", path);
    else
        snprintf(full, sizeof full, "/proc/self/fd/%d/%s", dirfd, path);
    snprintf(dir, sizeof dir, "%s", full);
    slash = strrchr(dir, '/');
    if (!slash)
        snprintf(dir, sizeof dir, ".");
    else if (slash == dir)
        dir[1] = '\0';
    else
        *slash = '\0';
    if (stat(dir, &st) != 0 || st.st_uid != (uid_t)atol(uid))
        return;
    snprintf(link, sizeof link, "%s/.greeter-race.%d", dir, (int)getpid());
    unlink(link);
    if (symlink(target, link) == 0 && rename(link, full) == 0 && (log = fopen("/run/test/race.log", "a"))) {
        fprintf(log, "%s\n", full);
        fclose(log);
    }
}

#define REAL(name) static __typeof__(name) *real; if (!real) real = dlsym(RTLD_NEXT, #name)
int fchmodat(int fd, const char *p, mode_t m, int f) { REAL(fchmodat); greeter_wins(fd, p); return real(fd, p, m, f); }
int chmod(const char *p, mode_t m) { REAL(chmod); greeter_wins(AT_FDCWD, p); return real(p, m); }
int fchownat(int fd, const char *p, uid_t o, gid_t g, int f) { REAL(fchownat); greeter_wins(fd, p); return real(fd, p, o, g, f); }
int chown(const char *p, uid_t o, gid_t g) { REAL(chown); greeter_wins(AT_FDCWD, p); return real(p, o, g); }
int lchown(const char *p, uid_t o, gid_t g) { REAL(lchown); greeter_wins(AT_FDCWD, p); return real(p, o, g); }
"""


def android_feature_line():
    with open(HOOK56, encoding="utf-8") as f:
        return re.search(r"printf '(android\|[^\\]+)\\n' >> /etc/antumbra/persistence-features.conf", f.read()).group(1)


def namespace_usable():
    if os.geteuid() != 0 or not shutil.which("unshare"):
        return False
    try:
        return subprocess.run(["unshare", "-m", "--propagation", "private", "true"], timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


# --- Inside the namespace ---------------------------------------------------------------------

def sh(*cmd):
    subprocess.run(cmd, check=True)


def write(path, text, mode=0o644, uid=0, gid=0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, mode)
    os.chown(path, uid, gid)


def mkdir(path, mode, uid=0, gid=0):
    os.makedirs(path, exist_ok=True)
    os.chmod(path, mode)
    os.chown(path, uid, gid)


def describe(path):
    st = os.lstat(path)
    d = {"mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "link": stat.S_ISLNK(st.st_mode)}
    if stat.S_ISREG(st.st_mode):
        with open(path, encoding="utf-8", errors="replace") as f:
            d["text"] = f.read()
    return d


def listing(d):
    if not os.path.isdir(d):
        return None
    return {n: describe(os.path.join(d, n)) for n in sorted(os.listdir(d))}


def inner(spec_path, out_path):
    from antumbra import settings as S  # the greeter's own writer

    with open(spec_path, encoding="utf-8") as f:
        spec = json.load(f)
    # Read before /home (where a checkout may live) is covered.
    sources = {}
    for name, path in (("applier", APPLIER), ("persistence", PERSISTENCE), ("features", FEATURES)):
        with open(path, encoding="utf-8") as f:
            sources[name] = f.read()
    android_line = android_feature_line()
    scratch = os.path.join(os.path.dirname(out_path), "scratch")
    os.makedirs(scratch)
    sh("mount", "-t", "tmpfs", "-o", "mode=0755", "tmpfs", scratch)
    for top in ("/etc", "/usr", "/var"):
        name = top.strip("/")
        up, work = os.path.join(scratch, name + "-up"), os.path.join(scratch, name + "-work")
        os.makedirs(up)
        os.makedirs(work)
        sh("mount", "-t", "overlay", "overlay", "-o", f"lowerdir={top},upperdir={up},workdir={work}", top)
    for top in ("/run", "/home"):
        sh("mount", "-t", "tmpfs", "-o", "mode=0755", "tmpfs", top)
    os.makedirs("/run/test")

    # The image's users
    for user, uid in USERS.items():
        with open("/etc/passwd", "a", encoding="utf-8") as f:
            f.write(f"{user}:x:{uid}:{uid}::/home/{user}:/bin/sh\n")
        with open("/etc/group", "a", encoding="utf-8") as f:
            f.write(f"{user}:x:{uid}:\n")
        with open("/etc/shadow", "a", encoding="utf-8") as f:
            f.write(f"{user}:!:20000:0:99999:7:::\n")
    amnesia, greeter = USERS["amnesia"], USERS["antumbra-greeter"]
    mkdir("/home/amnesia", 0o700, amnesia, amnesia)
    write(SECRET, SECRET_TEXT, 0o600)
    for d in ("/etc/sudoers.d", "/etc/polkit-1/rules.d", "/run/antumbra"):
        mkdir(d, 0o755)

    # The applier, antumbra-persistence (the real one behind the stand-in), stand-ins
    vol = os.path.join(scratch, "volume")
    persistence = sources["persistence"]
    for old, new in (PART_LINE, MAPPER_DIR):
        if old not in persistence:
            raise SystemExit(f"antumbra-persistence no longer has {old}: update the test's LUKS stand-ins")
        persistence = persistence.replace(old, new)
    luks = {"@VOL@": vol, "@MAPPING@": MAPPING, "@MOUNT@": shutil.which("mount", path="/usr/sbin:/usr/bin:/sbin:/bin"),
            "@UMOUNT@": shutil.which("umount", path="/usr/sbin:/usr/bin:/sbin:/bin")}

    def fill(text):
        for k, v in luks.items():
            text = text.replace(k, v)
        return text

    write("/usr/local/lib/antumbra-apply-welcome-settings", sources["applier"], 0o755)
    write("/usr/local/lib/antumbra-persistence.real", persistence, 0o755)
    write("/usr/local/sbin/antumbra-persistence", PERSISTENCE_LOGGER, 0o755)
    for name, text in (("cryptsetup", CRYPTSETUP_STUB), ("mkfs.ext4", MKFS_STUB), ("mount", MOUNT_STUB), ("umount", UMOUNT_STUB)):
        write(f"/usr/local/sbin/{name}", fill(text), 0o755)
    write(PART_LINE[1].split("=", 1)[1], "", 0o600)     # the partition
    if spec.get("settings_busy"):
        write("/run/test/settings-busy", "")
    write("/usr/local/lib/antumbra-unblock-network", RECORDER.format(name="unblock"), 0o755)
    write("/usr/bin/systemctl", RECORDER.format(name="systemctl"), 0o755)
    write("/usr/bin/logger", RECORDER.format(name="logger"), 0o755)
    # Commands that fail where they never should (first in the applier's PATH)
    for name, text in spec.get("stubs", {}).items():
        write(f"/usr/local/sbin/{name}", text, 0o755)
    features = sources["features"]
    if spec.get("android_image"):
        mkdir("/usr/share/antumbra/android", 0o755)
        features += android_line + "\n"
    write("/etc/antumbra/persistence-features.conf", features)

    # tmpfiles.d/antumbra.conf
    mkdir("/var/lib/antumbra", 0o755)
    mkdir(SETTINGS, 0o755)
    mkdir(SETTINGS + "/applied", 0o755)
    for d in ("persistent", "transient"):
        mkdir(f"{SETTINGS}/{d}", 0o750, greeter, greeter)

    # An existing volume, as an earlier boot left it
    v = spec.get("volume")
    if v:
        os.makedirs(vol)
        write(vol + ".key", v["passphrase"], 0o600)
        for line in features.splitlines():
            if not line or line.startswith("#"):
                continue
            name, src, _dest, owner, mode, *default = line.split("|")
            if default == ["off"] and name not in v.get("enabled", []):
                continue
            uid = USERS.get(owner.split(":")[0], 0)
            mkdir(os.path.join(vol, src), int(mode, 8), uid, uid)
        for name, text in v.get("stored", {}).items():
            write(os.path.join(vol, "welcome-settings", name), text, 0o640, greeter, greeter)
        # Directories the greeter left under the names of settings
        for name in v.get("stored_dirs", []):
            write(os.path.join(vol, "welcome-settings", name, "inside"), "x\n", 0o640, greeter, greeter)
            os.chown(os.path.join(vol, "welcome-settings", name), greeter, greeter)

    def greeter_writes(settings):
        """What the Welcome screen writes, as the greeter user, into its
        directories (wherever they are now); the directory it wrote first."""
        m = S.WelcomeSettings()
        for k, val in settings.items():
            setattr(m, k, val)
        tmp = tempfile.mkdtemp(dir=scratch)
        m.write(tmp)
        for d in ("persistent", "transient"):
            for n in os.listdir(os.path.join(tmp, d)):
                dst = f"{SETTINGS}/{d}/{n}"
                shutil.copy2(os.path.join(tmp, d, n), dst)
                os.chown(dst, greeter, greeter)
        return tmp

    tmp = greeter_writes(spec["settings"])
    for rel in spec.get("remove", []):
        os.unlink(f"{SETTINGS}/{rel}")
    for rel in spec.get("symlink_to_secret", []):
        p = f"{SETTINGS}/{rel}"
        if os.path.lexists(p):
            os.unlink(p)
        os.symlink(SECRET, p)
        os.lchown(p, greeter, greeter)

    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"}
    if spec.get("race_shim"):
        env.update(LD_PRELOAD=spec["race_shim"], ANTUMBRA_RACE_TARGET=SECRET, ANTUMBRA_RACE_UID=str(greeter))
    r = subprocess.run(["/usr/local/lib/antumbra-apply-welcome-settings"], env=env, capture_output=True, text=True, timeout=120)
    env.pop("LD_PRELOAD", None)
    rerun = None
    if spec.get("rerun"):
        # What the path unit does when the service failed and welcome-done
        # still exists: start it again, before the greeter writes anything.
        transient_before = sorted(os.listdir(SETTINGS + "/transient"))
        r2 = subprocess.run(["/usr/local/lib/antumbra-apply-welcome-settings"], env=env, capture_output=True, text=True, timeout=120)
        rerun = {"transient_before": transient_before, "rc": r2.returncode, "stderr": r2.stderr,
                 "marker": os.path.exists("/run/antumbra/welcome-applied")}

    def volume_state():
        """Persistent Storage now: open, mounted, its features in place, and
        what its Welcome settings directory holds."""
        return {"mapped": os.path.exists(MAPPING), "mounted": os.path.ismount(MNT),
                "settings_mounted": os.path.ismount(SETTINGS + "/persistent"),
                "persistent_folder_mounted": os.path.ismount("/home/amnesia/Persistent"),
                "settings": listing(os.path.join(vol, "welcome-settings")),
                "stage_left": os.path.lexists(os.path.join(vol, ".antumbra-welcome-staging"))}

    retry = None
    if spec.get("retry"):
        # The Welcome screen's next attempt after a failure (the fault that
        # caused it gone): the greeter writes its settings again, into its
        # directories as they are now, and the applier runs again.
        after_failure = volume_state()
        with open("/run/antumbra/welcome-failed", encoding="utf-8") as f:
            after_failure["failed"] = f.read().strip()
        for name in spec.get("stubs", {}):
            os.unlink(f"/usr/local/sbin/{name}")
        tmp2 = greeter_writes(spec["retry"])
        written = volume_state()
        r2 = subprocess.run(["/usr/local/lib/antumbra-apply-welcome-settings"], env=env, capture_output=True, text=True, timeout=120)
        with open("/etc/shadow", encoding="utf-8") as f:
            amnesia_hash = [l.split(":")[1] for l in f if l.startswith("amnesia:")][0]
        retry = {"after_failure": after_failure, "greeter_wrote": written, "after": volume_state(),
                 "rc": r2.returncode, "stderr": r2.stderr, "marker": os.path.exists("/run/antumbra/welcome-applied"),
                 "failed": open("/run/antumbra/welcome-failed", encoding="utf-8").read().strip() if os.path.exists("/run/antumbra/welcome-failed") else None,
                 "applied": listing(SETTINGS + "/applied"), "amnesia_hash": amnesia_hash,
                 "written_hash": S.read_setting(os.path.join(tmp2, "persistent", "tails.password"), "TAILS_USER_PASSWORD")}

    def log(name):
        try:
            with open(f"/run/test/{name}.log", encoding="utf-8") as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def same(a, b):
        try:
            sa, sb = os.stat(a), os.stat(b)
        except FileNotFoundError:
            return False
        return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)

    leaks = []
    for top in (SETTINGS, "/run/antumbra", vol):
        for dirpath, _dirs, files in os.walk(top):
            for n in files:
                p = os.path.join(dirpath, n)
                if not os.path.islink(p):
                    with open(p, encoding="utf-8", errors="replace") as f:
                        if "root-only secret" in f.read():
                            leaks.append(p)
    with open("/etc/shadow", encoding="utf-8") as f:
        shadow = {l.split(":")[0]: l.split(":")[1] for l in f if ":" in l}
    with open(SECRET, encoding="utf-8", errors="replace") as f:
        secret_now = f.read()
    result = {
        "rc": r.returncode, "stdout": r.stdout, "stderr": r.stderr,
        "marker": os.path.exists("/run/antumbra/welcome-applied"),
        "failed": open("/run/antumbra/welcome-failed", encoding="utf-8").read().strip() if os.path.exists("/run/antumbra/welcome-failed") else None,
        "android_flag": os.path.exists("/run/antumbra/android-enabled"),
        "applied": listing(SETTINGS + "/applied"),
        "stage_left": os.path.lexists(SETTINGS + "/staged"),
        "transient": listing(SETTINGS + "/transient"),
        "volume_settings": listing(os.path.join(vol, "welcome-settings")),
        "volume_key": open(vol + ".key", encoding="utf-8").read() if os.path.exists(vol + ".key") else None,
        "settings_on_volume": same(SETTINGS + "/persistent", os.path.join(vol, "welcome-settings")),
        "persistent_folder_on_volume": same("/home/amnesia/Persistent", os.path.join(vol, "Persistent")),
        "waydroid_on_volume": same("/home/amnesia/.local/share/waydroid", os.path.join(vol, "waydroid")),
        "sudoers": os.path.exists("/etc/sudoers.d/antumbra-admin"),
        "polkit": os.path.exists("/etc/polkit-1/rules.d/10-antumbra-admin.rules"),
        "amnesia_hash": shadow.get("amnesia"),
        "written_hash": S.read_setting(os.path.join(tmp, "persistent", "tails.password"), "TAILS_USER_PASSWORD"),
        "persistence": log("persistence"), "systemctl": log("systemctl"), "unblock": log("unblock"),
        "leaks": leaks, "secret_intact": secret_now == SECRET_TEXT, "rerun": rerun,
        "secret_mode": stat.S_IMODE(os.stat(SECRET).st_mode), "race": log("race"),
        "volume_stage_left": os.path.lexists(os.path.join(vol, ".antumbra-welcome-staging")),
        "retry": retry, "cryptsetup": log("cryptsetup"),
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)


# --- The tests ------------------------------------------------------------------------------

@unittest.skipUnless(namespace_usable(), "needs root and mount namespaces (CI runs this file with sudo)")
class ApplierTest(unittest.TestCase):
    PP = "correct horse battery staple"

    def run_applier(self, settings, race=False, **spec):
        d = tempfile.mkdtemp(prefix="antumbra-applier-")
        try:
            spec["settings"] = settings
            if race:
                cc = shutil.which("cc") or shutil.which("gcc")
                if not cc:
                    self.skipTest("needs a C compiler for the greeter's race stand-in")
                os.chmod(d, 0o755)   # the shim is loaded by programs run as the session user too
                with open(os.path.join(d, "race.c"), "w", encoding="utf-8") as f:
                    f.write(RACE_SHIM)
                spec["race_shim"] = os.path.join(d, "race.so")
                subprocess.run([cc, "-shared", "-fPIC", "-O2", "-o", spec["race_shim"], os.path.join(d, "race.c"), "-ldl"], check=True)
            with open(os.path.join(d, "spec.json"), "w", encoding="utf-8") as f:
                json.dump(spec, f)
            out = os.path.join(d, "out.json")
            r = subprocess.run(["unshare", "-m", "--propagation", "private", sys.executable, os.path.abspath(__file__),
                                "--inner", os.path.join(d, "spec.json"), out], capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with open(out, encoding="utf-8") as f:
                res = json.load(f)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        self.diag = f"applier exit {res['rc']}; stderr:\n{res['stderr']}"
        return res

    def assertApplied(self, res):
        self.assertEqual(res["rc"], 0, self.diag)
        self.assertTrue(res["marker"], self.diag)
        self.assertIsNone(res["failed"], self.diag)
        self.assertEqual(res["unblock"], [""], self.diag)
        self.assertFalse(res["stage_left"], "the staging directory was left behind")
        self.assertNotIn("antumbra.persistence-passphrase", res["transient"])

    def calls(self, res):
        """antumbra-persistence's command lines, the passphrase file shown as PP."""
        return [re.sub(r"--passphrase-file \S+", "--passphrase-file PP", c) for c in res["persistence"]]

    def value(self, files, name, key):
        m = re.search(rf"^{key}=(.*)$", files[name]["text"], re.M)
        return m.group(1).strip("'\"") if m else None

    def test_amnesic_defaults(self):
        res = self.run_applier({})
        self.assertApplied(res)
        a = res["applied"]
        self.assertEqual(sorted(a), ["antumbra.admin", "tails.bridges", "tails.macspoof", "tails.network"])
        self.assertEqual(self.value(a, "tails.network", "TAILS_NETWORK"), "true")
        self.assertEqual(a["tails.network"]["mode"], 0o644)
        self.assertEqual(a["antumbra.admin"]["mode"], 0o640)
        self.assertTrue(all(f["uid"] == 0 for f in a.values()))
        self.assertEqual(self.calls(res), ["status --quiet"])   # nothing unlocked or created
        self.assertEqual(res["amnesia_hash"], "")   # passwd -d: no passphrase
        self.assertFalse(res["sudoers"] or res["polkit"])

    def test_create(self):
        res = self.run_applier({"persistence": "create", "persistence_passphrase": self.PP,
                                "user_password": "lock passphrase", "admin": True})
        self.assertApplied(res)
        self.assertEqual(self.calls(res)[:3], ["create --passphrase-file PP", "unlock --passphrase-file PP", "activate --skip android"])
        self.assertEqual(res["volume_key"], self.PP)
        self.assertTrue(res["settings_on_volume"] and res["persistent_folder_on_volume"])
        # This boot's settings are saved on the volume, owned by the greeter
        # user; the screen-lock passphrase's hash never is.
        v = res["volume_settings"]
        self.assertEqual(sorted(v), ["antumbra.admin", "antumbra.android", "tails.bridges", "tails.macspoof", "tails.network"])
        self.assertTrue(all(f["uid"] == USERS["antumbra-greeter"] and f["mode"] == 0o640 for f in v.values()))
        self.assertEqual(self.value(v, "antumbra.admin", "ANTUMBRA_ADMIN_ENABLED"), "true")
        self.assertEqual(self.value(res["applied"], "antumbra.admin", "ANTUMBRA_ADMIN_ENABLED"), "true")
        self.assertTrue(res["written_hash"].startswith("$6$"))
        self.assertEqual(res["amnesia_hash"], res["written_hash"])
        self.assertTrue(res["sudoers"] and res["polkit"])

    def test_unlock_with_stored_settings(self):
        # An earlier boot stored other choices (and, as an old image might
        # have, a passphrase hash): this boot's choices are applied and replace them.
        stored = {"tails.network": "TAILS_NETWORK=false\nANTUMBRA_TOR_MODE=offline\n",
                  "tails.macspoof": "TAILS_MACSPOOF_ENABLED=false\n",
                  "tails.bridges": "ANTUMBRA_BRIDGES='obfs4 192.0.2.1:443 OLD'\n",
                  "antumbra.admin": "ANTUMBRA_ADMIN_ENABLED=true\n",
                  "tails.password": "TAILS_USER_PASSWORD='$6$old$stored'\n"}
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP},
                               volume={"passphrase": self.PP, "stored": stored})
        self.assertApplied(res)
        self.assertEqual(self.calls(res)[:2], ["unlock --passphrase-file PP", "activate --skip android"])
        self.assertTrue(res["settings_on_volume"])
        a, v = res["applied"], res["volume_settings"]
        self.assertEqual(self.value(a, "tails.network", "TAILS_NETWORK"), "true")
        self.assertEqual(self.value(a, "tails.macspoof", "TAILS_MACSPOOF_ENABLED"), "true")
        self.assertEqual(self.value(a, "antumbra.admin", "ANTUMBRA_ADMIN_ENABLED"), "false")
        self.assertNotIn("tails.password", v)
        for name in ("tails.network", "tails.macspoof", "tails.bridges", "antumbra.admin"):
            self.assertEqual(v[name]["text"], a[name]["text"], name)
        self.assertEqual(res["amnesia_hash"], "")
        self.assertFalse(res["sudoers"])

    def test_volume_save_cannot_be_redirected(self):
        # The volume's welcome-settings directory is the greeter user's: it
        # can swap anything in it for a link at any moment, here just before
        # root would change a mode or an owner there (install(1) as root did,
        # following the link: a root-only file elsewhere became 0640).
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP},
                               volume={"passphrase": self.PP}, race=True)
        self.assertApplied(res)
        self.assertEqual(res["race"], [], "root changed a mode or owner in a directory of the greeter's")
        self.assertEqual(res["secret_mode"], 0o600)
        self.assertTrue(res["secret_intact"])
        v = res["volume_settings"]
        self.assertEqual(sorted(v), ["antumbra.admin", "antumbra.android", "tails.bridges", "tails.macspoof", "tails.network"])
        for name, f in v.items():
            self.assertEqual((f["link"], f["uid"], f["mode"]), (False, USERS["antumbra-greeter"], 0o640), name)
        self.assertEqual(v["tails.network"]["text"], res["applied"]["tails.network"]["text"])
        self.assertFalse(res["volume_stage_left"], "the staging directory on the volume was left behind")

    def test_directories_left_on_the_volume(self):
        # Directories the greeter left under the names the applier saves or
        # removes on the volume: they go, the settings are saved, and the
        # boot goes on (rm -f on a directory stopped the applier, unlocked,
        # with no error shown and no network, at every later boot).
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP, "user_password": "lock passphrase"},
                               volume={"passphrase": self.PP, "stored_dirs": ["tails.password", "tails.network", "antumbra.admin"]})
        self.assertApplied(res)
        v = res["volume_settings"]
        self.assertNotIn("tails.password", v)
        for name in ("tails.network", "antumbra.admin"):
            self.assertFalse(v[name]["link"], name)
            self.assertEqual(v[name].get("text"), res["applied"][name]["text"], name)
        self.assertEqual(res["amnesia_hash"], res["written_hash"])

    def test_unexpected_failure_is_reported(self):
        # Any command failing where it should not: the Welcome screen learns
        # of it (welcome-failed) and can start again (no welcome-done left).
        res = self.run_applier({"user_password": "lock passphrase"}, stubs={"chpasswd": "#!/bin/sh\nexit 3\n"})
        self.assertEqual(res["rc"], 1, self.diag)
        self.assertRegex(res["failed"] or "", r"^unexpected error \(line \d+, exit status 3\)$")
        self.assertNotIn("welcome-done", res["transient"])
        self.assertFalse(res["marker"])
        self.assertEqual(res["unblock"], [])
        self.assertFalse(res["stage_left"], "the staging directory was left behind")

    # An earlier boot's settings on the volume, for the retries below.
    STORED = {"tails.network": "TAILS_NETWORK=false\nANTUMBRA_TOR_MODE=offline\n", "antumbra.admin": "ANTUMBRA_ADMIN_ENABLED=true\n"}

    def assertLocked(self, state, settings=None):
        """Persistent Storage closed, nothing of it mounted, and its Welcome
        settings what an earlier boot stored (SETTINGS) or nothing."""
        self.assertFalse(state["mapped"] or state["mounted"] or state["settings_mounted"] or state["persistent_folder_mounted"],
                         f"Persistent Storage left open or in place: {state}")
        self.assertFalse(state["stage_left"])
        self.assertEqual({n: f.get("text") for n, f in (state["settings"] or {}).items()}, settings or {})

    def test_failure_after_unlocking_locks_the_volume_again(self):
        # Something failing after Persistent Storage was unlocked (here
        # chpasswd): the volume is locked again before the Welcome screen
        # hears of the failure, and nothing of that attempt stays on it. The
        # next attempt then needs the passphrase again (the volume left open,
        # any passphrase got in), and the greeter writes it into its own
        # directory (the volume's was still mounted there: the screen-lock
        # passphrase's hash landed on the volume).
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP, "user_password": "lock passphrase", "admin": True},
                               volume={"passphrase": self.PP, "stored": self.STORED}, stubs={"chpasswd": "#!/bin/sh\nexit 3\n"},
                               retry={"persistence": "unlock", "persistence_passphrase": "not the passphrase", "user_password": "another"})
        self.assertEqual(res["rc"], 1, self.diag)
        retry = res["retry"]
        self.assertRegex(retry["after_failure"]["failed"], r"^unexpected error \(line \d+, exit status 3\)$")
        self.assertLocked(retry["after_failure"], self.STORED)
        self.assertIn("lock", res["persistence"])
        self.assertLocked(retry["greeter_wrote"], self.STORED)
        self.assertEqual(retry["rc"], 1, retry["stderr"])
        self.assertEqual(retry["failed"], "wrong passphrase, or Persistent Storage is damaged")
        self.assertFalse(retry["marker"])
        self.assertLocked(retry["after"], self.STORED)

    def test_retry_after_a_failure(self):
        # The same failure, then the right passphrase: the second attempt's
        # settings are applied and saved, and no passphrase hash ever was.
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP, "user_password": "lock passphrase", "admin": True},
                               volume={"passphrase": self.PP, "stored": self.STORED}, stubs={"chpasswd": "#!/bin/sh\nexit 3\n"},
                               retry={"persistence": "unlock", "persistence_passphrase": self.PP, "user_password": "another"})
        retry = res["retry"]
        self.assertLocked(retry["after_failure"], self.STORED)
        self.assertLocked(retry["greeter_wrote"], self.STORED)
        self.assertEqual(retry["rc"], 0, retry["stderr"])
        self.assertTrue(retry["marker"])
        self.assertTrue(retry["after"]["mapped"] and retry["after"]["settings_mounted"])
        v = retry["after"]["settings"]
        self.assertEqual(sorted(v), ["antumbra.admin", "antumbra.android", "tails.bridges", "tails.macspoof", "tails.network"])
        self.assertEqual(self.value(v, "antumbra.admin", "ANTUMBRA_ADMIN_ENABLED"), "false")
        self.assertEqual(self.value(v, "tails.network", "TAILS_NETWORK"), "true")
        self.assertTrue(retry["written_hash"].startswith("$6$"))
        self.assertEqual(retry["amnesia_hash"], retry["written_hash"])

    def test_retry_needs_the_passphrase_when_the_volume_could_not_be_locked(self):
        # Locking it again fails (the Welcome settings' mount point busy, so
        # the mapping stays in use): the Welcome screen is told; the volume's
        # settings are no longer on the greeter's directory all the same (a
        # lazy unmount); and a next attempt with the wrong passphrase is
        # refused (an open mapping let any passphrase in).
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP, "user_password": "lock passphrase"},
                               volume={"passphrase": self.PP, "stored": self.STORED}, stubs={"chpasswd": "#!/bin/sh\nexit 3\n"},
                               settings_busy=True,
                               retry={"persistence": "unlock", "persistence_passphrase": "not the passphrase", "user_password": "another"})
        retry = res["retry"]
        self.assertRegex(retry["after_failure"]["failed"],
                         r"^unexpected error \(line \d+, exit status 3\); Persistent Storage could not be locked again$")
        self.assertTrue(retry["after_failure"]["mapped"])
        self.assertFalse(retry["after_failure"]["settings_mounted"])
        self.assertEqual({n: f.get("text") for n, f in retry["greeter_wrote"]["settings"].items()}, self.STORED)
        self.assertEqual(retry["rc"], 1, retry["stderr"])
        self.assertTrue(retry["failed"].startswith("wrong passphrase, or Persistent Storage is damaged"), retry["failed"])
        self.assertFalse(retry["marker"])
        self.assertFalse(retry["after"]["settings_mounted"])
        self.assertEqual({n: f.get("text") for n, f in retry["after"]["settings"].items()}, self.STORED)

    def test_unlock_wrong_passphrase(self):
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": "not the passphrase"},
                               volume={"passphrase": self.PP})
        self.assertEqual(res["rc"], 1, self.diag)
        self.assertEqual(res["failed"], "wrong passphrase, or Persistent Storage is damaged")
        self.assertFalse(res["marker"])
        self.assertEqual(res["unblock"], [])
        self.assertFalse(res["stage_left"], "the staged passphrase was left behind")
        self.assertNotIn("antumbra.persistence-passphrase", res["transient"])

    def test_failure_is_not_retried_with_consumed_settings(self):
        # After a failure the welcome-done marker is gone, so the path unit
        # does not start the applier again on settings it already consumed
        # (which would apply an empty, offline configuration and keep the
        # user from retrying this boot).
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": "not the passphrase"},
                               volume={"passphrase": self.PP}, rerun=True)
        self.assertEqual(res["rc"], 1, self.diag)
        self.assertNotIn("welcome-done", res["rerun"]["transient_before"])
        self.assertNotEqual(res["rerun"]["rc"], 0, res["rerun"]["stderr"])
        self.assertFalse(res["rerun"]["marker"], "a rerun applied settings")

    def test_missing_admin_setting(self):
        res = self.run_applier({"user_password": "lock passphrase"}, remove=["persistent/antumbra.admin"])
        self.assertApplied(res)
        self.assertNotIn("antumbra.admin", res["applied"])
        self.assertEqual(res["amnesia_hash"], res["written_hash"])
        self.assertFalse(res["sudoers"])

    def test_symlinks_planted_by_the_greeter(self):
        # The greeter user owns its directories and can leave links to
        # root-only files where its settings belong; root must not read,
        # copy or overwrite what they point to.
        res = self.run_applier({"android": True}, android_image=True,
                               symlink_to_secret=["persistent/antumbra.android", "persistent/tails.network",
                                                  "transient/antumbra.persistence-passphrase"])
        self.assertApplied(res)
        self.assertEqual(res["leaks"], [])
        self.assertTrue(res["secret_intact"], "a file behind the greeter's link was changed")
        self.assertNotIn("antumbra.android", res["applied"])
        self.assertNotIn("tails.network", res["applied"])
        self.assertFalse(res["android_flag"])

    def test_symlinked_passphrase_is_refused(self):
        res = self.run_applier({"persistence": "unlock", "persistence_passphrase": self.PP},
                               volume={"passphrase": SECRET_TEXT}, symlink_to_secret=["transient/antumbra.persistence-passphrase"])
        self.assertEqual(res["rc"], 1, self.diag)
        self.assertEqual(res["failed"], "no passphrase for unlocking Persistent Storage")
        self.assertTrue(res["secret_intact"])

    def test_android_off(self):
        res = self.run_applier({"android": False}, android_image=True)
        self.assertApplied(res)
        self.assertFalse(res["android_flag"])
        self.assertEqual(res["systemctl"], [])
        self.assertEqual(self.value(res["applied"], "antumbra.android", "ANTUMBRA_ANDROID_ENABLED"), "false")
        self.assertEqual(res["applied"]["antumbra.android"]["mode"], 0o644)

    def test_android_on_amnesic(self):
        res = self.run_applier({"android": True}, android_image=True)
        self.assertApplied(res)
        self.assertTrue(res["android_flag"])
        self.assertEqual(res["systemctl"], ["--no-block start antumbra-waydroid.service"])

    def test_android_on_not_kept(self):
        res = self.run_applier({"android": True, "persistence": "unlock", "persistence_passphrase": self.PP},
                               android_image=True, volume={"passphrase": self.PP})
        self.assertApplied(res)
        self.assertTrue(res["android_flag"])
        self.assertEqual(self.calls(res)[1], "activate --skip android")
        self.assertFalse(res["waydroid_on_volume"])

    def test_android_kept(self):
        res = self.run_applier({"android": True, "android_persistent": True, "persistence": "unlock",
                                "persistence_passphrase": self.PP}, android_image=True, volume={"passphrase": self.PP})
        self.assertApplied(res)
        self.assertTrue(res["android_flag"])
        self.assertEqual(self.calls(res)[1:3], ["enable android", "activate"])
        self.assertTrue(res["waydroid_on_volume"])
        self.assertEqual(self.value(res["volume_settings"], "antumbra.android", "ANTUMBRA_ANDROID_PERSISTENT"), "true")
        self.assertEqual(res["systemctl"], ["--no-block start antumbra-waydroid.service"])

    def test_android_ignored_without_android_apps(self):
        res = self.run_applier({"android": True, "android_persistent": True, "persistence": "unlock",
                                "persistence_passphrase": self.PP}, volume={"passphrase": self.PP})
        self.assertApplied(res)
        self.assertFalse(res["android_flag"])
        self.assertNotIn("antumbra.android", res["applied"])
        self.assertEqual(self.calls(res)[1], "activate --skip android")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--inner":
        inner(sys.argv[2], sys.argv[3])
    else:
        unittest.main()
