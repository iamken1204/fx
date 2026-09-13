import ctypes
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

binary = os.path.abspath(sys.argv[1])
source_line = sys.argv[2]
label = sys.argv[3]
os.makedirs('/tmp/fx-tty-investigation', exist_ok=True)
master, slave = pty.openpty()
name = os.ttyname(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
finished = threading.Event()
output = bytearray()
log = []

def drain():
    while not finished.is_set():
        if select.select([master], [], [], 0.1)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                return

def observe(pid):
    for i in range(3):
        time.sleep(1)
        snapshot = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,time=,%cpu=,state='], capture_output=True, text=True).stdout.strip()
        print('CPU_SAMPLE', snapshot, flush=True)
        log.append('CPU_SAMPLE ' + snapshot + '\n')
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

with tempfile.TemporaryDirectory(prefix='fx-poll-race-') as home:
    commands = [
        f'breakpoint set -f shell_runtime.zig -l {source_line} -i 30',
        f'process launch -i {name} -o {name} -e /tmp/fx-tty-investigation/{label}-stderr.txt',
        'script print("TARGETPID",lldb.debugger.GetSelectedTarget().GetProcess().GetProcessID(),flush=True)',
        f'script import ctypes; print("REVOKE_RESULT",ctypes.CDLL(None).revoke(b"{name}"),flush=True)',
        'breakpoint disable 1',
        'continue',
    ]
    argv = ['lldb', '-b', binary]
    for command in commands:
        argv += ['-o', command]
    for command in ['bt', 'process kill', 'quit']:
        argv += ['-k', command]
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(os.environ, HOME=home, TERM='xterm-256color'))
    reader = threading.Thread(target=drain)
    reader.start()
    target = None
    watcher = None
    try:
        for line in process.stdout:
            print(line, end='', flush=True)
            log.append(line)
            if line.startswith('TARGETPID '):
                target = int(line.split()[1])
            if line.startswith('REVOKE_RESULT ') and target:
                watcher = threading.Thread(target=observe, args=(target,))
                watcher.start()
        process.wait()
        if watcher:
            watcher.join()
    finally:
        finished.set()
        reader.join()
        os.close(master)
        os.close(slave)
print('TUI_OUTPUT_BYTES', len(output), flush=True)
with open(f'/tmp/fx-tty-investigation/{label}-lldb.txt', 'w') as result:
    result.writelines(log)
