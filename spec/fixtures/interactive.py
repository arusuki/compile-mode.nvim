"""Line-oriented process with observable signal handlers for integration tests."""
import os
import signal
import sys

def emit(text):
    # One pipe write keeps concurrent parent/child messages and readiness atomic.
    os.write(sys.stdout.fileno(), (text + "\n").encode())


child = None
if "--child" in sys.argv:
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGUSR1, lambda *_: emit("child:USR1"))
        emit("child:ready")
        while True:
            signal.pause()

for name in ("SIGINT", "SIGUSR1", "SIGQUIT"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), lambda *_, name=name: emit("signal:" + name))

prompt_newlines = 0
if "--prompt-newlines" in sys.argv:
    prompt_newlines = int(sys.argv[sys.argv.index("--prompt-newlines") + 1])
if "--enable-echo" in sys.argv:
    import termios
    attrs = termios.tcgetattr(sys.stdin.fileno())
    attrs[3] |= termios.ECHO
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, attrs)
os.write(sys.stdout.fileno(), b"prompt>" + b"\n" * prompt_newlines)
try:
    for line in sys.stdin:
        text = line.rstrip("\n")
        if text == "quit":
            break
        if "--repeat-input" in sys.argv:
            emit(text)
        emit("received:" + text)
    emit("eof")
finally:
    if child:
        os.kill(child, signal.SIGTERM)
        os.waitpid(child, 0)
