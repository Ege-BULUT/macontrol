import os, subprocess, time
import sys; d = sys.argv[1]; os.makedirs(d, exist_ok=True)
def free():
    subprocess.run(["sync"]); time.sleep(2)
    s = os.statvfs(d); return s.f_bavail * s.f_frsize
subprocess.run(["dd", "if=/dev/urandom", f"of={d}/orig.bin", "bs=1m", "count=64"], stderr=subprocess.DEVNULL)
subprocess.run(["cp", "-c", f"{d}/orig.bin", f"{d}/clone.bin"])
subprocess.run(["ln", f"{d}/orig.bin", f"{d}/orig_hl.bin"])
MiB = 1 << 20
for step in ["clone.bin", "orig_hl.bin", "orig.bin"]:
    a = free(); os.remove(f"{d}/{step}"); b = free()
    print(f"rm {step:12s} freed {(b - a) / MiB:+8.2f} MiB")
