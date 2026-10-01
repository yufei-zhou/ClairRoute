#!/usr/bin/env python3
"""Read-only installation guard. Never restores settings or terminates a process."""
from pathlib import Path
import ctypes
import errno
import json
import os
import stat

if os.geteuid() != 0:
    raise SystemExit('Run this installation guard as root so protected recovery records can be inspected.')

base = Path('/Library/Application Support/ClairRoute')


def inspect(path, directory=False, private=False, applications_parent=False):
    """lexists semantics: dangling symlinks must not count as an absent resource."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    valid_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    writable = info.st_mode & 0o022
    if applications_parent and info.st_gid == 80:
        writable = info.st_mode & 0o002  # macOS /Applications is normally root:admin 0775.
    if (not valid_type or info.st_uid != 0 or writable or
            (private and info.st_mode & 0o077) or (not directory and info.st_nlink != 1)):
        raise SystemExit('Unsafe owned installation path; refusing to proceed: ' + str(path))
    return True


for path in [Path('/Library'), Path('/Library/Application Support'), Path('/Library/LaunchDaemons')]:
    if not inspect(path, directory=True):
        raise SystemExit('A required system directory is missing: ' + str(path))
inspect(Path('/Applications'), directory=True, applications_parent=True)
for path in [base, base/'state', base/'run', base/'bin']:
    inspect(path, directory=True)
inspect(Path('/Applications/ClairRoute.app'), directory=True)
for path in [base/'bin/mihomo', base/'CoreManifest.json', base/'state/helper.log',
             Path('/Library/LaunchDaemons/local.nano.ClairRoute.Helper.plist'),
             Path('/Library/LaunchDaemons/local.nano.ClairRoute.RecoveryGuard.plist'),
             base/'state/geosite.dat', base/'GeoManifest.json', base/'state/recovery-guard.log',
             base/'state/recovery.lock', base/'run/recovery-guard.json', base/'run/helper-ready.json']:
    inspect(path)

journal = base/'state/network-recovery.json'
if inspect(journal, private=True):
    try:
        if journal.stat().st_size > 1_048_576:
            raise ValueError('oversized journal')
        document = json.loads(journal.read_bytes())
        if document.get('version') != 1 or not isinstance(document.get('leases'), dict) or document['leases']:
            raise ValueError('pending or invalid journal')
    except Exception:
        raise SystemExit('Network recovery is pending or unreadable. Restore in ClairRoute first; the journal was preserved.')

# Only absence means clean. A stale record still needs the Helper's ownership checks.
for name in ['core-process.json', 'trial-lease.json', 'recovery-in-progress.json']:
    record = base/'state'/name
    if record.exists() or record.is_symlink():
        raise SystemExit('A core/trial/recovery record remains. Restore/stop ClairRoute before installing or removing it.')

# Inspect executable paths, not names: other clients may also run a binary called mihomo.
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libproc.proc_listallpids.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
for attempt in range(3):
    count = libproc.proc_listallpids(None, 0)
    if count <= 0 or count > 1_000_000:
        raise SystemExit('Cannot enumerate processes safely; installation/removal is blocked.')
    capacity = count + 256
    pids = (ctypes.c_int * capacity)()
    found = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    if found <= 0:
        raise SystemExit('Cannot enumerate processes safely; installation/removal is blocked.')
    if found < capacity:
        break
else:
    raise SystemExit('The process list did not stabilize; retry after quitting ClairRoute.')
for pid in pids[:found]:
    if pid <= 0:
        continue
    buffer = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        continue  # Exited processes and kernel-owned pseudo-processes have no executable path.
    executable = os.fsdecode(buffer.value)
    if executable == str(base/'bin/mihomo'):
        raise SystemExit('The installed ClairRoute core is still running. Restore/stop it before proceeding.')
    if Path(executable).name == 'ClairRoute':
        raise SystemExit('Quit ClairRoute after restoring the network, then run this script again.')

libc = ctypes.CDLL(None, use_errno=True)
libc.if_nametoindex.argtypes = [ctypes.c_char_p]
libc.if_nametoindex.restype = ctypes.c_uint
ctypes.set_errno(0)
index = libc.if_nametoindex(b'utun197')
if index:
    raise SystemExit('utun197 still exists. Restore/stop ClairRoute before proceeding.')
if ctypes.get_errno() not in (0, errno.ENXIO, errno.ENODEV, errno.ENOENT):
    raise SystemExit('Cannot inspect the reserved TUN interface; refusing installation/removal.')
print('No pending ClairRoute network takeover was found.')
