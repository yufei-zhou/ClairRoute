#!/usr/bin/env python3
"""One read-only installed-service readiness check. Never starts/stops a service."""
import ctypes
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

BASE = Path('/Library/Application Support/ClairRoute')
APP = Path('/Applications/ClairRoute.app/Contents/MacOS')


class BSDInfo(ctypes.Structure):
    # Public arm64 macOS sys/proc_info.h: PROC_PIDTBSDINFO, MAXCOMLEN = 16.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in
                 ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_seconds', ctypes.c_uint64),
                 ('start_microseconds', ctypes.c_uint64)]


class Timeval(ctypes.Structure):
    _fields_ = [('seconds', ctypes.c_long), ('microseconds', ctypes.c_int)]


class Timebase(ctypes.Structure):
    _fields_ = [('numerator', ctypes.c_uint32), ('denominator', ctypes.c_uint32)]


def fail(message):
    raise ValueError(message)


def integer(value):
    if type(value) is not int or value < 0:
        fail('Invalid readiness integer.')
    return value


def protected_record(name):
    for directory in (Path('/Library'), BASE.parent, BASE, BASE / 'run'):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or
                info.st_mode & (0o077 if directory == BASE / 'run' else 0o022)):
            fail('Unsafe readiness directory.')
    descriptor = os.open(BASE / 'run' / name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                info.st_mode & 0o077 or info.st_nlink != 1 or not 0 < info.st_size <= 8192):
            fail('Unsafe readiness file.')
        data = stream.read(8193)
    if len(data) > 8192:
        fail('Oversized readiness record.')
    record = json.loads(data)
    if not isinstance(record, dict) or integer(record.get('version')) != 1:
        fail('Unsupported readiness record.')
    return record


def clock_now(libc):
    boot = Timeval()
    size = ctypes.c_size_t(ctypes.sizeof(boot))
    libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    libc.sysctlbyname.restype = ctypes.c_int
    if libc.sysctlbyname(b'kern.boottime', ctypes.byref(boot), ctypes.byref(size), None, 0) != 0 or boot.seconds <= 0:
        fail('Cannot read the recovery boot clock.')
    basis = Timebase()
    libc.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    libc.mach_timebase_info.restype = ctypes.c_int
    libc.mach_continuous_time.argtypes = []
    libc.mach_continuous_time.restype = ctypes.c_uint64
    if libc.mach_timebase_info(ctypes.byref(basis)) != 0 or basis.denominator == 0:
        fail('Cannot read the continuous recovery clock.')
    return boot.seconds, libc.mach_continuous_time() * basis.numerator // basis.denominator


def service_ready(libproc, boot, now, *, label, executable, filename, role, maximum_age):
    record = protected_record(filename)
    identity, clock = record.get('identity'), record.get('clock')
    if not isinstance(identity, dict) or not isinstance(clock, dict) or identity.get('role') != role:
        fail('Invalid readiness identity.')
    pid = integer(identity.get('pid'))
    stamp = integer(clock.get('continuousNanoseconds'))
    if pid <= 1 or integer(clock.get('bootID')) != boot or not 0 <= now - stamp < maximum_age:
        fail(executable + ' has no fresh readiness record.')
    result = subprocess.run(['/bin/launchctl', 'print', 'system/' + label],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, timeout=3, check=False)
    if (result.returncode != 0 or not re.search(r'^\s*state = running\s*$', result.stdout, re.M) or
            not re.search(r'^\s*pid = ' + str(pid) + r'\s*$', result.stdout, re.M)):
        fail(executable + ' is not the running launchd job.')
    info = BSDInfo()
    if (libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info) or
            info.pid != pid or info.uid != 0 or info.ruid != 0 or info.status not in (2, 3) or
            info.start_seconds != integer(identity.get('startedSeconds')) or
            info.start_microseconds != integer(identity.get('startedMicroseconds'))):
        fail(executable + ' process identity differs from its readiness record.')
    path = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, path, len(path)) <= 0 or os.fsdecode(path.value) != str(APP / executable):
        fail(executable + ' is not running from its fixed installed path.')
    if role == 'helper' and record.get('ready') is not True:
        fail('Helper has not completed recovery and registered its network/power monitors.')


def main():
    if os.geteuid() != 0:
        fail('Run readiness inspection as root.')
    libc = ctypes.CDLL(None, use_errno=True)
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    libproc.proc_pidinfo.restype = ctypes.c_int
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    boot, now = clock_now(libc)
    service_ready(libproc, boot, now, label='local.nano.ClairRoute.RecoveryGuard',
        executable='ClairRouteRecoveryGuard', filename='recovery-guard.json',
        role='guardProcess', maximum_age=5_000_000_000)
    service_ready(libproc, boot, now, label='local.nano.ClairRoute.Helper',
        executable='ClairRouteHelper', filename='helper-ready.json',
        role='helper', maximum_age=10_000_000_000)
    print('Helper and independent RecoveryGuard are running and ready; proxy/TUN remains disabled.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        print('ClairRoute services are not yet confirmed ready. Installation must not commit.', file=sys.stderr)
        raise SystemExit(1)
