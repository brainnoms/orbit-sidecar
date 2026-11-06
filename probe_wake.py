# wake/CPU probe: proc_pid_rusage V2 counters for one pid over a window
import ctypes.util, struct, sys, time
libc = ctypes.CDLL(ctypes.util.find_library("system"))
class RU(ctypes.Structure):
    _fields_ = [("buf", ctypes.c_byte * 176)]  # rusage_info_v2 (v3 is 168+8; 176 safe)
def snap(pid):
    r = RU()
    rc = libc.proc_pid_rusage(ctypes.c_int(pid), 2, ctypes.byref(r))
    if rc != 0: sys.exit(f"proc_pid_rusage rc={rc} pid={pid}")
    b = bytes(r.buf)
    user, sys_ = struct.unpack_from("<QQ", b, 24)      # ns
    idle, int_ = struct.unpack_from("<QQ", b, 40)      # wkups
    return dict(user_ms=user/1e6, sys_ms=sys_/1e6, idle_wkups=idle, intr_wkups=int_)
pid = int(sys.argv[1]); secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30
a = snap(pid); t0 = time.time(); time.sleep(secs); b = snap(pid); dt = time.time() - t0
dw = (b["idle_wkups"]+b["intr_wkups"]-a["idle_wkups"]-a["intr_wkups"])
print(f"pid={pid} window={dt:.1f}s wakes=+{dw} ({dw/dt:.1f}/s) "
      f"idle=+{b['idle_wkups']-a['idle_wkups']} intr=+{b['intr_wkups']-a['intr_wkups']} "
      f"cpu={(b['user_ms']+b['sys_ms']-a['user_ms']-a['sys_ms'])/1000/dt*100:.1f}%")
