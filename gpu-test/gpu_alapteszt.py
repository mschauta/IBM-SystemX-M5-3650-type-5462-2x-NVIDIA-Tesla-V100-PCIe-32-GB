#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kíméletes alapműködés-teszt NVIDIA Tesla V100-hoz (Windows / TCC driver).

NEM stresszteszt. Amit csinál:
  1. Szenzorok, ECC-hibaszámlálók, kivont (retired) lapok, PCIe link, throttle okok ellenőrzése
  2. (Opcionális) teljesítménykorlát beállítása 150 W-ra a teszt idejére, majd visszaállítás
  3. CUDA inicializálás, eszközadatok, saját PTX kernelek fordítása (JIT)
  4. VRAM-teszt: a szabad memória nagy részének lefoglalása, mintázatok írása/ellenőrzése
  5. PCIe átvitel: host <-> GPU másolás, adatintegritás + sávszélesség
  6. Számítási helyesség: determinisztikus egész-aritmetikai kernel, CPU-n ellenőrizve
  7. Két rövid, kitöltési tényezővel (duty cycle) korlátozott könnyű terhelési szakasz,
     folyamatos hőmérséklet/fogyasztás-figyeléssel és automatikus leállítással
  8. Utóellenőrzés (ECC, PCIe replay számláló), összegzés + naplófájl

Függőség: csak a Python standard könyvtár + az NVIDIA driver (nvcuda.dll, nvml.dll).

Használat:
    python gpu_alapteszt.py                      # alapértelmezett, kíméletes futás
    python gpu_alapteszt.py --skip-load          # terhelési szakaszok nélkül
    python gpu_alapteszt.py --max-power 130      # szigorúbb fogyasztási vészhatár
    python gpu_alapteszt.py --ramp               # + fokozatos terhelés 150 -> 200 -> 250 W
    python gpu_alapteszt.py --ramp-only          # csak alapellenőrzés + fokozatos terhelés
    python gpu_alapteszt.py --ramp-only --ramp-steps 150,175,200 --ramp-seconds 90
    python gpu_alapteszt.py --gpu 1              # a második GPU tesztelése
    python gpu_alapteszt.py --gpu all            # minden GPU egymás után (külön naplóval)
A teljesítménykorlát beállításához rendszergazdaként kell futtatni (a --ramp ezzel
lépcsőnként hardveresen is korlátozza a fogyasztást a lépcső célja + 10 W-ra).
"""

import argparse
import ctypes
import datetime
import math
import os
import random
import struct
import subprocess
import sys
import threading
import time
from ctypes import (POINTER, Structure, byref, c_char_p, c_float, c_int, c_size_t,
                    c_uint, c_uint32, c_uint64, c_ulonglong, c_void_p)

MiB = 1024 * 1024
GiB = 1024 * MiB

# ---------------------------------------------------------------------------
# Naplózás (konzol + fájl)
# ---------------------------------------------------------------------------
class Log:
    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8")
        self.path = path

    def __call__(self, msg=""):
        print(msg, flush=True)
        self.f.write(msg + "\n")
        self.f.flush()

    def close(self):
        self.f.close()


log = None
results = []  # (név, státusz, részletek)


def result(name, status, detail=""):
    results.append((name, status, detail))
    log(f"  -> [{status}] {name}" + (f": {detail}" if detail else ""))


def section(title):
    log("")
    log("=" * 70)
    log(f" {title}")
    log("=" * 70)


# ---------------------------------------------------------------------------
# NVML (szenzorok, ECC, teljesítménykorlát)
# ---------------------------------------------------------------------------
class NvmlError(Exception):
    pass


class _Util(Structure):
    _fields_ = [("gpu", c_uint), ("memory", c_uint)]


THROTTLE_NAMES = {
    0x1: "GPU tétlen",
    0x2: "alkalmazás-órajel beállítás",
    0x4: "SW teljesítménykorlát",
    0x8: "HW lassítás",
    0x10: "Sync Boost",
    0x20: "SW termikus lassítás",
    0x40: "HW termikus lassítás",
    0x80: "HW POWER BRAKE (külső tápjel!)",
    0x100: "kijelző órajel",
}
THROTTLE_HW_BAD = 0x8 | 0x40 | 0x80


def decode_reasons(mask):
    if mask is None:
        return "n/a"
    if mask == 0:
        return "nincs"
    return ", ".join(n for b, n in THROTTLE_NAMES.items() if mask & b) or hex(mask)


class NVML:
    def __init__(self, pci_bus_id=None):
        sysroot = os.environ.get("SystemRoot", r"C:\Windows")
        candidates = [
            os.path.join(sysroot, "System32", "nvml.dll"),
            r"C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll",
            "nvml.dll",
            "libnvidia-ml.so.1",
        ]
        self.lib = None
        for p in candidates:
            try:
                self.lib = ctypes.CDLL(p)
                break
            except OSError:
                continue
        if self.lib is None:
            raise NvmlError("nvml.dll nem található")
        self.lib.nvmlErrorString.restype = c_char_p
        self._check("nvmlInit_v2")
        self.h = c_void_p()
        r = -1
        if pci_bus_id:
            r = self._raw("nvmlDeviceGetHandleByPciBusId_v2", pci_bus_id.encode(), byref(self.h))
        if r != 0:
            self._check("nvmlDeviceGetHandleByIndex_v2", c_uint(0), byref(self.h))

    def _raw(self, name, *args):
        fn = getattr(self.lib, name, None)
        if fn is None:
            return -1
        return fn(*args)

    def _check(self, name, *args):
        r = self._raw(name, *args)
        if r != 0:
            raise NvmlError(f"{name} hiba: {self.err(r)}")

    def err(self, r):
        if r == -1:
            return "függvény nem elérhető"
        try:
            return self.lib.nvmlErrorString(r).decode()
        except Exception:
            return f"kód {r}"

    def uint(self, name, *pre):
        v = c_uint()
        r = self._raw(name, self.h, *pre, byref(v))
        return v.value if r == 0 else None

    def name(self):
        buf = ctypes.create_string_buffer(96)
        r = self._raw("nvmlDeviceGetName", self.h, buf, c_uint(96))
        return buf.value.decode(errors="replace") if r == 0 else "?"

    def reasons(self):
        v = c_ulonglong()
        for fn in ("nvmlDeviceGetCurrentClocksEventReasons",
                   "nvmlDeviceGetCurrentClocksThrottleReasons"):
            if self._raw(fn, self.h, byref(v)) == 0:
                return v.value
        return None

    def ecc(self, err_type, counter_type):
        v = c_ulonglong()
        r = self._raw("nvmlDeviceGetTotalEccErrors", self.h, c_int(err_type), c_int(counter_type), byref(v))
        return v.value if r == 0 else None

    def retired_pages(self, cause):
        cnt = c_uint(0)
        r = self._raw("nvmlDeviceGetRetiredPages", self.h, c_int(cause), byref(cnt), None)
        return cnt.value if r in (0, 7) else None  # 7 = INSUFFICIENT_SIZE

    def retired_pending(self):
        v = c_int()
        r = self._raw("nvmlDeviceGetRetiredPagesPendingStatus", self.h, byref(v))
        return bool(v.value) if r == 0 else None

    def power_limits(self):
        cur = self.uint("nvmlDeviceGetPowerManagementLimit")
        mn, mx = c_uint(), c_uint()
        r = self._raw("nvmlDeviceGetPowerManagementLimitConstraints", self.h, byref(mn), byref(mx))
        return cur, (mn.value if r == 0 else None), (mx.value if r == 0 else None)

    def set_power_limit(self, mw):
        return self._raw("nvmlDeviceSetPowerManagementLimit", self.h, c_uint(int(mw)))

    def sample(self):
        u = _Util()
        ru = self._raw("nvmlDeviceGetUtilizationRates", self.h, byref(u))
        p = self.uint("nvmlDeviceGetPowerUsage")
        return {
            "t": time.time(),
            "temp": self.uint("nvmlDeviceGetTemperature", c_int(0)),
            "power": p / 1000.0 if p is not None else None,
            "sm": self.uint("nvmlDeviceGetClockInfo", c_int(1)),
            "mem": self.uint("nvmlDeviceGetClockInfo", c_int(2)),
            "gen": self.uint("nvmlDeviceGetCurrPcieLinkGeneration"),
            "width": self.uint("nvmlDeviceGetCurrPcieLinkWidth"),
            "util": u.gpu if ru == 0 else None,
            "reasons": self.reasons(),
        }

    def shutdown(self):
        self._raw("nvmlShutdown")


# ---------------------------------------------------------------------------
# Háttérfigyelő: hőmérséklet / fogyasztás / HW lassítás -> vészleállítás
# ---------------------------------------------------------------------------
class Monitor(threading.Thread):
    def __init__(self, nvml, max_temp, max_power, interval=0.5):
        super().__init__(daemon=True)
        self.nvml = nvml
        self.max_temp = max_temp
        self.max_power = max_power
        self.interval = interval
        self.stop_evt = threading.Event()
        self.lock = threading.Lock()
        self.samples = []
        self.abort_reason = None
        self.last = None

    def run(self):
        over = 0
        while not self.stop_evt.is_set():
            try:
                s = self.nvml.sample()
            except Exception as e:  # szenzorolvasási hiba is gyanús
                self.abort_reason = f"szenzorolvasási hiba: {e}"
                break
            with self.lock:
                self.samples.append(s)
                self.last = s
            if s["temp"] is not None and s["temp"] >= self.max_temp:
                self.abort_reason = f"hőmérséklet {s['temp']} °C >= {self.max_temp} °C"
            if s["power"] is not None and s["power"] > self.max_power:
                over += 1
                if over >= 3:
                    self.abort_reason = f"fogyasztás {s['power']:.0f} W > {self.max_power} W (tartósan)"
            else:
                over = 0
            if s["reasons"] is not None and s["reasons"] & THROTTLE_HW_BAD:
                self.abort_reason = f"hardveres lassítás jelzés: {decode_reasons(s['reasons'] & THROTTLE_HW_BAD)}"
            self.stop_evt.wait(self.interval)

    def window(self, t_from):
        with self.lock:
            return [s for s in self.samples if s["t"] >= t_from]

    def stop(self):
        self.stop_evt.set()


def summarize(samples):
    def mx(k):
        v = [s[k] for s in samples if s[k] is not None]
        return max(v) if v else None

    def avg(k):
        v = [s[k] for s in samples if s[k] is not None]
        return sum(v) / len(v) if v else None

    reasons = 0
    for s in samples:
        if s["reasons"]:
            reasons |= s["reasons"]
    return {"temp_max": mx("temp"), "power_max": mx("power"), "power_avg": avg("power"),
            "sm_max": mx("sm"), "gen_max": mx("gen"), "width_max": mx("width"),
            "util_avg": avg("util"), "reasons": reasons & ~0x1}


def fmt(v, unit="", nd=0):
    if v is None:
        return "n/a"
    return f"{v:.{nd}f}{unit}" if isinstance(v, float) else f"{v}{unit}"


# ---------------------------------------------------------------------------
# CUDA Driver API ctypes-szal
# ---------------------------------------------------------------------------
class CudaError(Exception):
    def __init__(self, what, code, name):
        super().__init__(f"{what}: {name} ({code})")
        self.code = code


CUDA_ERROR_OUT_OF_MEMORY = 2


class Cuda:
    def __init__(self):
        lib = None
        for p in ("nvcuda.dll", "libcuda.so.1"):
            try:
                lib = ctypes.CDLL(p)
                break
            except OSError:
                continue
        if lib is None:
            raise RuntimeError("nvcuda.dll nem tölthető be (NVIDIA driver?)")
        self.lib = lib

        def P(name, *argtypes):
            f = getattr(lib, name)
            f.restype = c_int
            f.argtypes = argtypes
            return f

        self.cuInit = P("cuInit", c_uint)
        self.cuDriverGetVersion = P("cuDriverGetVersion", POINTER(c_int))
        self.cuDeviceGetCount = P("cuDeviceGetCount", POINTER(c_int))
        self.cuDeviceGet = P("cuDeviceGet", POINTER(c_int), c_int)
        self.cuDeviceGetName = P("cuDeviceGetName", c_char_p, c_int, c_int)
        self.cuDeviceTotalMem = P("cuDeviceTotalMem_v2", POINTER(c_size_t), c_int)
        self.cuDeviceGetAttribute = P("cuDeviceGetAttribute", POINTER(c_int), c_int, c_int)
        self.cuDeviceGetPCIBusId = P("cuDeviceGetPCIBusId", c_char_p, c_int, c_int)
        self.cuDevicePrimaryCtxRetain = P("cuDevicePrimaryCtxRetain", POINTER(c_void_p), c_int)
        self.cuDevicePrimaryCtxRelease = P("cuDevicePrimaryCtxRelease_v2", c_int)
        self.cuCtxSetCurrent = P("cuCtxSetCurrent", c_void_p)
        self.cuCtxSynchronize = P("cuCtxSynchronize")
        self.cuModuleLoadDataEx = P("cuModuleLoadDataEx", POINTER(c_void_p), c_char_p, c_uint,
                                    POINTER(c_int), POINTER(c_void_p))
        self.cuModuleGetFunction = P("cuModuleGetFunction", POINTER(c_void_p), c_void_p, c_char_p)
        self.cuMemGetInfo = P("cuMemGetInfo_v2", POINTER(c_size_t), POINTER(c_size_t))
        self.cuMemAlloc = P("cuMemAlloc_v2", POINTER(c_uint64), c_size_t)
        self.cuMemFree = P("cuMemFree_v2", c_uint64)
        self.cuMemAllocHost = P("cuMemAllocHost_v2", POINTER(c_void_p), c_size_t)
        self.cuMemFreeHost = P("cuMemFreeHost", c_void_p)
        self.cuMemcpyHtoD = P("cuMemcpyHtoD_v2", c_uint64, c_void_p, c_size_t)
        self.cuMemcpyDtoH = P("cuMemcpyDtoH_v2", c_void_p, c_uint64, c_size_t)
        self.cuMemsetD32 = P("cuMemsetD32_v2", c_uint64, c_uint, c_size_t)
        self.cuLaunchKernel = P("cuLaunchKernel", c_void_p, c_uint, c_uint, c_uint, c_uint, c_uint,
                                c_uint, c_uint, c_void_p, POINTER(c_void_p), POINTER(c_void_p))
        self.cuGetErrorName = P("cuGetErrorName", c_int, POINTER(c_char_p))
        self.ctx = None
        self.dev = None

    def check(self, r, what):
        if r != 0:
            s = c_char_p()
            name = "?"
            if self.cuGetErrorName(r, byref(s)) == 0 and s.value:
                name = s.value.decode()
            raise CudaError(what, r, name)

    # --- eszköz ---
    def init(self, index=0):
        self.check(self.cuInit(0), "cuInit")
        n = c_int()
        self.check(self.cuDeviceGetCount(byref(n)), "cuDeviceGetCount")
        if n.value < 1:
            raise RuntimeError("Nincs CUDA eszköz")
        if not 0 <= index < n.value:
            raise RuntimeError(f"Nincs {index}. GPU (elérhető: 0..{n.value - 1})")
        d = c_int()
        self.check(self.cuDeviceGet(byref(d), index), "cuDeviceGet")
        self.dev = d.value
        ctx = c_void_p()
        self.check(self.cuDevicePrimaryCtxRetain(byref(ctx), self.dev), "cuDevicePrimaryCtxRetain")
        self.ctx = ctx
        self.check(self.cuCtxSetCurrent(ctx), "cuCtxSetCurrent")
        return n.value

    def release(self):
        if self.ctx is not None:
            self.cuDevicePrimaryCtxRelease(self.dev)
            self.ctx = None

    def driver_version(self):
        v = c_int()
        self.check(self.cuDriverGetVersion(byref(v)), "cuDriverGetVersion")
        return f"{v.value // 1000}.{(v.value % 1000) // 10}"

    def name(self):
        b = ctypes.create_string_buffer(256)
        self.check(self.cuDeviceGetName(b, 256, self.dev), "cuDeviceGetName")
        return b.value.decode(errors="replace")

    def total_mem(self):
        v = c_size_t()
        self.check(self.cuDeviceTotalMem(byref(v), self.dev), "cuDeviceTotalMem")
        return v.value

    def attr(self, a):
        v = c_int()
        self.check(self.cuDeviceGetAttribute(byref(v), a, self.dev), f"cuDeviceGetAttribute({a})")
        return v.value

    def pci_bus_id(self):
        b = ctypes.create_string_buffer(64)
        self.check(self.cuDeviceGetPCIBusId(b, 64, self.dev), "cuDeviceGetPCIBusId")
        return b.value.decode()

    # --- memória ---
    def mem_info(self):
        f, t = c_size_t(), c_size_t()
        self.check(self.cuMemGetInfo(byref(f), byref(t)), "cuMemGetInfo")
        return f.value, t.value

    def alloc(self, size):
        p = c_uint64()
        self.check(self.cuMemAlloc(byref(p), size), f"cuMemAlloc({size // MiB} MiB)")
        return p.value

    def free(self, p):
        self.check(self.cuMemFree(p), "cuMemFree")

    def alloc_host(self, size):
        p = c_void_p()
        self.check(self.cuMemAllocHost(byref(p), size), "cuMemAllocHost")
        return p.value

    def free_host(self, p):
        self.check(self.cuMemFreeHost(p), "cuMemFreeHost")

    def htod(self, dst, src, size):
        self.check(self.cuMemcpyHtoD(dst, src, size), "cuMemcpyHtoD")

    def dtoh(self, dst, src, size):
        self.check(self.cuMemcpyDtoH(dst, src, size), "cuMemcpyDtoH")

    def memset32(self, p, val, count):
        self.check(self.cuMemsetD32(p, val, count), "cuMemsetD32")

    def sync(self):
        self.check(self.cuCtxSynchronize(), "cuCtxSynchronize")

    # --- kernelek ---
    def load_ptx(self, ptx):
        logbuf = ctypes.create_string_buffer(8192)
        opts = (c_int * 2)(5, 6)  # CU_JIT_ERROR_LOG_BUFFER, CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES
        vals = (c_void_p * 2)(ctypes.cast(logbuf, c_void_p), c_void_p(8192))
        mod = c_void_p()
        r = self.cuModuleLoadDataEx(byref(mod), ptx.encode() + b"\0", 2, opts, vals)
        if r != 0:
            raise RuntimeError(f"PTX fordítási hiba ({r}): {logbuf.value.decode(errors='replace')}")
        return mod

    def function(self, mod, name):
        f = c_void_p()
        self.check(self.cuModuleGetFunction(byref(f), mod, name.encode()), f"cuModuleGetFunction({name})")
        return f

    def launch(self, func, grid, block, *args):
        params = (c_void_p * len(args))(*[ctypes.cast(ctypes.pointer(a), c_void_p) for a in args])
        self.check(self.cuLaunchKernel(func, grid, 1, 1, block, 1, 1, 0, None, params, None),
                   "cuLaunchKernel")


# CUdevice_attribute értékek
ATTR = {
    "clock_khz": 13, "sm_count": 16, "ecc": 32, "pci_bus": 33, "tcc": 35,
    "mem_clock_khz": 36, "bus_width": 37, "cc_major": 75, "cc_minor": 76,
}

# ---------------------------------------------------------------------------
# PTX kernelek (sm_70, kézzel írva - nincs szükség nvcc/MSVC-re)
#   fill_pattern : p[i] = ((base+i) & mask) ^ seed
#   check_pattern: hibás szavak számlálása ugyanerre a képletre
#   lcg_work     : x = tid; iters-szer x = x*1664525 + 1013904223 (mod 2^32)
# ---------------------------------------------------------------------------
PTX = r"""
.version 7.0
.target sm_70
.address_size 64

.visible .entry fill_pattern(
    .param .u64 fp_ptr, .param .u64 fp_n, .param .u64 fp_base,
    .param .u32 fp_seed, .param .u32 fp_mask)
{
    .reg .pred %p<2>;
    .reg .b32  %r<10>;
    .reg .b64  %rd<10>;
    ld.param.u64 %rd1, [fp_ptr];
    ld.param.u64 %rd2, [fp_n];
    ld.param.u64 %rd3, [fp_base];
    ld.param.u32 %r1, [fp_seed];
    ld.param.u32 %r2, [fp_mask];
    cvta.to.global.u64 %rd1, %rd1;
    mov.u32 %r3, %ctaid.x;
    mov.u32 %r4, %ntid.x;
    mov.u32 %r5, %tid.x;
    mov.u32 %r6, %nctaid.x;
    mul.wide.u32 %rd4, %r3, %r4;
    cvt.u64.u32 %rd5, %r5;
    add.u64 %rd4, %rd4, %rd5;
    mul.wide.u32 %rd6, %r6, %r4;
FP_LOOP:
    setp.ge.u64 %p1, %rd4, %rd2;
    @%p1 bra FP_DONE;
    add.u64 %rd7, %rd4, %rd3;
    cvt.u32.u64 %r7, %rd7;
    and.b32 %r8, %r7, %r2;
    xor.b32 %r9, %r8, %r1;
    shl.b64 %rd8, %rd4, 2;
    add.u64 %rd9, %rd1, %rd8;
    st.global.u32 [%rd9], %r9;
    add.u64 %rd4, %rd4, %rd6;
    bra.uni FP_LOOP;
FP_DONE:
    ret;
}

.visible .entry check_pattern(
    .param .u64 cp_ptr, .param .u64 cp_n, .param .u64 cp_base,
    .param .u32 cp_seed, .param .u32 cp_mask, .param .u64 cp_err)
{
    .reg .pred %p<3>;
    .reg .b32  %r<12>;
    .reg .b64  %rd<12>;
    ld.param.u64 %rd1, [cp_ptr];
    ld.param.u64 %rd2, [cp_n];
    ld.param.u64 %rd3, [cp_base];
    ld.param.u32 %r1, [cp_seed];
    ld.param.u32 %r2, [cp_mask];
    ld.param.u64 %rd10, [cp_err];
    cvta.to.global.u64 %rd1, %rd1;
    cvta.to.global.u64 %rd10, %rd10;
    mov.u32 %r3, %ctaid.x;
    mov.u32 %r4, %ntid.x;
    mov.u32 %r5, %tid.x;
    mov.u32 %r6, %nctaid.x;
    mul.wide.u32 %rd4, %r3, %r4;
    cvt.u64.u32 %rd5, %r5;
    add.u64 %rd4, %rd4, %rd5;
    mul.wide.u32 %rd6, %r6, %r4;
CP_LOOP:
    setp.ge.u64 %p1, %rd4, %rd2;
    @%p1 bra CP_DONE;
    add.u64 %rd7, %rd4, %rd3;
    cvt.u32.u64 %r7, %rd7;
    and.b32 %r8, %r7, %r2;
    xor.b32 %r9, %r8, %r1;
    shl.b64 %rd8, %rd4, 2;
    add.u64 %rd9, %rd1, %rd8;
    ld.global.u32 %r10, [%rd9];
    setp.eq.u32 %p2, %r10, %r9;
    @%p2 bra CP_NEXT;
    atom.global.add.u32 %r11, [%rd10], 1;
CP_NEXT:
    add.u64 %rd4, %rd4, %rd6;
    bra.uni CP_LOOP;
CP_DONE:
    ret;
}

.visible .entry lcg_work(.param .u64 lw_out, .param .u32 lw_iters)
{
    .reg .pred %p<2>;
    .reg .b32  %r<10>;
    .reg .b64  %rd<4>;
    ld.param.u64 %rd1, [lw_out];
    ld.param.u32 %r1, [lw_iters];
    cvta.to.global.u64 %rd1, %rd1;
    mov.u32 %r2, %ctaid.x;
    mov.u32 %r3, %ntid.x;
    mov.u32 %r4, %tid.x;
    mad.lo.u32 %r5, %r2, %r3, %r4;
    mov.u32 %r6, %r5;
    mov.u32 %r7, 0;
    mov.u32 %r8, 1664525;
    mov.u32 %r9, 1013904223;
LW_LOOP:
    setp.ge.u32 %p1, %r7, %r1;
    @%p1 bra LW_DONE;
    mad.lo.u32 %r6, %r6, %r8, %r9;
    add.u32 %r7, %r7, 1;
    bra.uni LW_LOOP;
LW_DONE:
    mul.wide.u32 %rd2, %r5, 4;
    add.u64 %rd3, %rd1, %rd2;
    st.global.u32 [%rd3], %r6;
    ret;
}
"""

LCG_A, LCG_C, M32 = 1664525, 1013904223, 0xFFFFFFFF


def lcg_jump(n):
    """Az x -> a*x+c leképezés n-szeres kompozíciója zárt alakban: (A, C), x_n = A*x0 + C."""
    ra, rc = 1, 0
    ba, bc = LCG_A, LCG_C
    while n:
        if n & 1:
            ra, rc = (ba * ra) & M32, (ba * rc + bc) & M32
        ba, bc = (ba * ba) & M32, (ba * bc + bc) & M32
        n >>= 1
    return ra, rc


# ---------------------------------------------------------------------------
# Tesztlépések
# ---------------------------------------------------------------------------
def precheck(nvml, args):
    section("1. Előzetes állapotellenőrzés (NVML)")
    s = nvml.sample()
    log(f"  GPU (NVML)          : {nvml.name()}")
    log(f"  Hőmérséklet         : {fmt(s['temp'], ' °C')}")
    log(f"  Fogyasztás          : {fmt(s['power'], ' W', 1)}")
    log(f"  SM / mem órajel     : {fmt(s['sm'], ' MHz')} / {fmt(s['mem'], ' MHz')}")
    log(f"  PCIe link (most)    : Gen{fmt(s['gen'])} x{fmt(s['width'])}")
    log(f"  PCIe link max       : Gen{fmt(nvml.uint('nvmlDeviceGetMaxPcieLinkGeneration'))} "
        f"x{fmt(nvml.uint('nvmlDeviceGetMaxPcieLinkWidth'))}"
        f"  (GPU képessége: Gen{fmt(nvml.uint('nvmlDeviceGetGpuMaxPcieLinkGeneration'))})")
    log(f"  Throttle okok       : {decode_reasons(s['reasons'])}")
    cur, mn, mx = nvml.power_limits()
    log(f"  Teljesítménykorlát  : {fmt(cur and cur / 1000, ' W')}  (min {fmt(mn and mn / 1000, ' W')}, max {fmt(mx and mx / 1000, ' W')})")

    ecc = {
        "javított (volatile)": nvml.ecc(0, 0), "javíthatatlan (volatile)": nvml.ecc(1, 0),
        "javított (összesített)": nvml.ecc(0, 1), "javíthatatlan (összesített)": nvml.ecc(1, 1),
    }
    for k, v in ecc.items():
        log(f"  ECC {k:<26}: {fmt(v)}")
    rp_sbe, rp_dbe, rp_pend = nvml.retired_pages(0), nvml.retired_pages(1), nvml.retired_pending()
    log(f"  Kivont lapok (SBE/DBE): {fmt(rp_sbe)} / {fmt(rp_dbe)}, függőben: {fmt(rp_pend)}")
    replay = nvml.uint("nvmlDeviceGetPcieReplayCounter")
    log(f"  PCIe replay számláló: {fmt(replay)}")

    ok = True
    if s["temp"] is None:
        result("Hőmérséklet-szenzor", "HIBA", "nem olvasható")
        ok = False
    elif s["temp"] >= args.max_idle_temp:
        result("Üresjárati hőmérséklet", "HIBA",
               f"{s['temp']} °C >= {args.max_idle_temp} °C: hűtés nem megfelelő, teszt leáll")
        ok = False
    elif s["temp"] >= 60:
        result("Üresjárati hőmérséklet", "FIGYELEM", f"{s['temp']} °C (magas üresjáratra)")
    else:
        result("Üresjárati hőmérséklet", "OK", f"{s['temp']} °C")

    if s["reasons"] is not None and s["reasons"] & THROTTLE_HW_BAD:
        result("HW lassítás jelzés", "HIBA", decode_reasons(s["reasons"] & THROTTLE_HW_BAD))
        ok = False

    if all(v is None for v in ecc.values()):
        result("ECC", "INFO", "ECC ki van kapcsolva, a hibaszámlálók nem elérhetők "
                              "(bekapcsolás: rendszergazdaként 'nvidia-smi -e 1', majd újraindítás)")
    elif ecc["javíthatatlan (összesített)"]:
        result("ECC előzmények", "FIGYELEM", f"{ecc['javíthatatlan (összesített)']} javíthatatlan hiba a múltban")
    else:
        result("ECC előzmények", "OK", "nincs javíthatatlan hiba")
    if rp_pend:
        result("Kivont lapok", "FIGYELEM", "lapkivonás függőben, újraindítás szükséges")
    elif (rp_sbe or 0) + (rp_dbe or 0) > 0:
        result("Kivont lapok", "FIGYELEM", f"SBE {rp_sbe}, DBE {rp_dbe}")
    else:
        result("Kivont lapok", "OK", "0")

    return ok, {"ecc_vol_c": ecc["javított (volatile)"], "ecc_vol_u": ecc["javíthatatlan (volatile)"],
                "replay": replay}


class PowerCtl:
    """Teljesítménykorlát állítása; az eredeti értéket megjegyzi és a végén visszaállítja."""

    def __init__(self, nvml):
        self.nvml = nvml
        self.orig, self.min, self.max = nvml.power_limits()
        self.changed = False
        self.last_err = None

    def current_w(self):
        cur = self.nvml.power_limits()[0]
        return cur / 1000 if cur is not None else None

    def set(self, watts):
        if self.orig is None:
            return False
        mw = int(watts * 1000)
        if self.min is not None:
            mw = max(mw, self.min)
        if self.max is not None:
            mw = min(mw, self.max)
        if self.nvml.power_limits()[0] == mw:
            return True
        r = self.nvml.set_power_limit(mw)
        self.last_err = r
        if r == 0:
            self.changed = True
            return True
        return False

    def restore(self):
        if not self.changed:
            return None
        r = self.nvml.set_power_limit(self.orig)
        self.changed = r != 0
        return r


def apply_power_limit(power, args):
    if args.no_power_limit:
        log("  Teljesítménykorlát módosítása kihagyva (--no-power-limit).")
        return
    if power.orig is None:
        log("  A teljesítménykorlát nem olvasható, nem módosítom.")
        return
    if power.set(args.power_limit):
        log(f"  Teljesítménykorlát a teszt idejére: {power.orig / 1000:.0f} W -> "
            f"{fmt(power.current_w(), ' W')} (a végén visszaáll)")
    elif power.last_err == 4:
        log("  FIGYELEM: nincs jogosultság a teljesítménykorlát beállításához.")
        log(f"            Rendszergazdaként futtatva {args.power_limit:.0f} W-ra korlátozom a teszt idejére.")
        log(f"            Védelem így is van: vészleállítás {args.max_power:.0f} W felett.")
    else:
        log(f"  FIGYELEM: teljesítménykorlát beállítása sikertelen: {power.nvml.err(power.last_err)}")


def device_info(cuda):
    section("2. CUDA eszköz")
    log(f"  CUDA driver API     : {cuda.driver_version()}")
    name = cuda.name()
    cc = (cuda.attr(ATTR["cc_major"]), cuda.attr(ATTR["cc_minor"]))
    sms = cuda.attr(ATTR["sm_count"])
    total = cuda.total_mem()
    log(f"  Név                 : {name}")
    log(f"  PCI busz            : {cuda.pci_bus_id()}")
    log(f"  Compute capability  : {cc[0]}.{cc[1]}")
    log(f"  SM-ek száma         : {sms}")
    log(f"  Max SM órajel       : {cuda.attr(ATTR['clock_khz']) // 1000} MHz")
    log(f"  Memória             : {total / GiB:.2f} GiB, {cuda.attr(ATTR['bus_width'])} bit, "
        f"{cuda.attr(ATTR['mem_clock_khz']) // 1000} MHz")
    log(f"  ECC engedélyezve    : {'igen' if cuda.attr(ATTR['ecc']) else 'nem'}")
    log(f"  TCC driver mód      : {'igen' if cuda.attr(ATTR['tcc']) else 'nem (WDDM)'}")

    problems = []
    if cc != (7, 0):
        problems.append(f"CC {cc[0]}.{cc[1]} (V100-nál 7.0 várt)")
    if sms != 80:
        problems.append(f"{sms} SM (V100-nál 80 várt)")
    if total < 15 * GiB:
        problems.append(f"{total / GiB:.1f} GiB memória (16 GiB várt)")
    if problems:
        result("Eszközadatok", "FIGYELEM", "; ".join(problems))
    else:
        result("Eszközadatok", "OK", f"{name}, CC 7.0, 80 SM, {total / GiB:.1f} GiB")
    return sms


def memory_test(cuda, k, sms, args, mon):
    section("3. VRAM-teszt (mintázat írás / ellenőrzés a GPU-n)")
    free, total = cuda.mem_info()
    target = min(int(free * args.mem_percent / 100), free - 512 * MiB)
    chunk = 256 * MiB
    log(f"  Szabad / teljes     : {free / GiB:.2f} / {total / GiB:.2f} GiB, cél: {target / GiB:.2f} GiB")

    chunks = []
    err_buf = None
    try:
        while sum(c[1] for c in chunks) + chunk <= target:
            try:
                chunks.append((cuda.alloc(chunk), chunk))
            except CudaError as e:
                if e.code == CUDA_ERROR_OUT_OF_MEMORY:
                    break
                raise
        allocated = sum(c[1] for c in chunks)
        if not chunks:
            result("VRAM foglalás", "HIBA", "egyetlen 256 MiB-os blokk sem foglalható")
            return
        result("VRAM foglalás", "OK" if allocated >= target * 0.95 else "FIGYELEM",
               f"{allocated / GiB:.2f} GiB ({len(chunks)} x 256 MiB)")

        err_buf = cuda.alloc(4 * len(chunks))
        grid, block = sms * 8, 256
        words_per_chunk = chunk // 4

        def fill(seed, mask):
            for i, (p, sz) in enumerate(chunks):
                cuda.launch(k["fill"], grid, block, c_uint64(p), c_uint64(sz // 4),
                            c_uint64(i * words_per_chunk), c_uint32(seed), c_uint32(mask))

        def check(seed, mask):
            cuda.memset32(err_buf, 0, len(chunks))
            for i, (p, sz) in enumerate(chunks):
                cuda.launch(k["check"], grid, block, c_uint64(p), c_uint64(sz // 4),
                            c_uint64(i * words_per_chunk), c_uint32(seed), c_uint32(mask),
                            c_uint64(err_buf + 4 * i))
            cuda.sync()
            errs = (c_uint32 * len(chunks))()
            cuda.dtoh(errs, err_buf, 4 * len(chunks))
            return list(errs)

        # Az ellenőrző kernel önellenőrzése: szándékosan elrontott szó észlelése
        fill(0x12345678, 0)
        cuda.memset32(chunks[0][0] + 4 * 777, 0x12345678 ^ 0x1, 1)
        cuda.sync()
        e = check(0x12345678, 0)
        if e[0] == 1 and sum(e) == 1:
            result("Ellenőrző kernel önteszt", "OK", "a szándékos 1 bites hibát pontosan észlelte")
        else:
            result("Ellenőrző kernel önteszt", "HIBA", f"várt 1 hiba, kapott {sum(e)}")
            return

        # Host oldali keresztellenőrzés (független a GPU-s ellenőrzőtől)
        sample = 64 * MiB
        host = ctypes.create_string_buffer(sample)
        ci = random.randrange(len(chunks))
        fill(0xA5A5A5A5, 0)
        cuda.sync()
        cuda.dtoh(host, chunks[ci][0], sample)
        if host.raw == (0xA5A5A5A5).to_bytes(4, "little") * (sample // 4):
            result("Host oldali visszaolvasás", "OK", f"64 MiB a(z) {ci}. blokkból bitre egyezik")
        else:
            result("Host oldali visszaolvasás", "HIBA", "a visszaolvasott adat eltér")

        patterns = [
            ("csupa 0", 0x00000000, 0), ("csupa 1", 0xFFFFFFFF, 0),
            ("0xAAAAAAAA", 0xAAAAAAAA, 0), ("0x55555555", 0x55555555, 0),
            ("cím-minta", 0x00000000, M32), ("inverz cím-minta", 0xFFFFFFFF, M32),
        ]
        total_err = 0
        bad_chunks = set()
        w_bw = r_bw = 0.0
        for ps in range(args.mem_passes):
            seed_rand = random.getrandbits(32)
            for name, seed, mask in patterns + [("cím XOR véletlen", seed_rand, M32)]:
                if mon.abort_reason:
                    result("VRAM-teszt", "HIBA", f"vészleállítás: {mon.abort_reason}")
                    return
                t0 = time.perf_counter()
                fill(seed, mask)
                cuda.sync()
                t1 = time.perf_counter()
                e = check(seed, mask)
                t2 = time.perf_counter()
                w_bw = max(w_bw, allocated / (t1 - t0) / 1e9)
                r_bw = max(r_bw, allocated / (t2 - t1) / 1e9)
                n = sum(e)
                total_err += n
                bad_chunks.update(i for i, x in enumerate(e) if x)
                log(f"  menet {ps + 1}/{args.mem_passes}  {name:<18} hibás szó: {n}")
        if total_err == 0:
            result("VRAM mintázatteszt", "OK",
                   f"{args.mem_passes} menet x {len(patterns) + 1} minta, {allocated / GiB:.2f} GiB, 0 hiba")
        else:
            offs = ", ".join(f"{i * 256} MiB" for i in sorted(bad_chunks)[:10])
            result("VRAM mintázatteszt", "HIBA", f"{total_err} hibás szó; érintett blokkok kezdete: {offs}")
        log(f"  Memória-sávszélesség (tájékoztató): írás ~{w_bw:.0f} GB/s, olvasás ~{r_bw:.0f} GB/s"
            f" (V100 elméleti: ~900 GB/s)")
    finally:
        cuda.sync() if chunks else None
        for p, _ in chunks:
            cuda.free(p)
        if err_buf:
            cuda.free(err_buf)


PCIE_BW = [None]  # a mért (min) PCIe sávszélesség GB/s, az utóellenőrzéshez


def pcie_test(cuda, mon):
    section("4. PCIe átvitel (host <-> GPU) és adatintegritás")
    size = 64 * MiB
    h_src = h_dst = d = None
    try:
        h_src = cuda.alloc_host(size)
        h_dst = cuda.alloc_host(size)
        d = cuda.alloc(size)
        ctypes.memmove(h_src, os.urandom(size), size)
        h2d, d2h, bad = [], [], 0
        for _ in range(5):
            ctypes.memset(h_dst, 0, size)
            t0 = time.perf_counter()
            cuda.htod(d, h_src, size)
            cuda.sync()
            t1 = time.perf_counter()
            cuda.dtoh(h_dst, d, size)
            cuda.sync()
            t2 = time.perf_counter()
            h2d.append(size / (t1 - t0) / 1e9)
            d2h.append(size / (t2 - t1) / 1e9)
            if ctypes.string_at(h_src, size) != ctypes.string_at(h_dst, size):
                bad += 1
        bh, bd = max(h2d), max(d2h)
        PCIE_BW[0] = min(bh, bd)
        log(f"  Host -> GPU : {bh:.2f} GB/s   GPU -> host : {bd:.2f} GB/s")
        log("  (Tájékoztató: Gen2 x16 ~6 GB/s, Gen3 x16 ~11-12 GB/s gyakorlatban)")
        if bad:
            result("PCIe adatintegritás", "HIBA", f"{bad}/5 körben eltérés a visszaolvasott adatban")
        else:
            result("PCIe adatintegritás", "OK", "5 x 64 MiB véletlen adat oda-vissza, bitre egyezik")
        if min(bh, bd) < 2.5:
            result("PCIe sávszélesség", "FIGYELEM", f"alacsony ({bh:.1f} / {bd:.1f} GB/s)")
        else:
            result("PCIe sávszélesség", "OK", f"{bh:.1f} / {bd:.1f} GB/s")
    finally:
        if d:
            cuda.free(d)
        if h_src:
            cuda.free_host(h_src)
        if h_dst:
            cuda.free_host(h_dst)


def run_lcg(cuda, k, out, blocks, threads, iters):
    n = blocks * threads
    cuda.memset32(out, 0, n)
    t0 = time.perf_counter()
    cuda.launch(k["lcg"], blocks, threads, c_uint64(out), c_uint32(iters))
    cuda.sync()
    dt = time.perf_counter() - t0
    buf = (c_uint32 * n)()
    cuda.dtoh(buf, out, 4 * n)
    a, c = lcg_jump(iters)
    got = buf[:]
    bad = 0
    if got != [(a * t + c) & M32 for t in range(n)]:
        bad = sum(1 for t in range(n) if got[t] != (a * t + c) & M32)
    return dt, bad


def compute_test(cuda, k, sms, out):
    section("5. Számítási helyesség (egész aritmetika, CPU-val ellenőrizve)")
    ok = True
    for blocks, threads, iters in ((1, 32, 1), (1, 256, 1000), (sms, 256, 10000), (sms * 2, 256, 50000)):
        dt, bad = run_lcg(cuda, k, out, blocks, threads, iters)
        log(f"  {blocks:>4} blokk x {threads} szál, {iters:>6} iteráció: {bad} hibás eredmény ({dt * 1000:.1f} ms)")
        ok &= bad == 0
    if ok:
        result("Számítási helyesség", "OK", "minden szál eredménye egyezik a CPU-s referenciával")
    else:
        result("Számítási helyesség", "HIBA", "eltérő eredmények a GPU-n")
    return ok


def load_stage(cuda, k, out, mon, name, blocks, threads, duty, seconds):
    log("")
    log(f"  --- {name}: {blocks} blokk x {threads} szál, kitöltés {duty * 100:.0f}%, {seconds} s ---")
    # kalibrálás: kb. 25 ms-os kernelhossz
    iters = 20000
    run_lcg(cuda, k, out, blocks, threads, iters)
    dt, _ = run_lcg(cuda, k, out, blocks, threads, iters)
    iters = max(1000, min(20_000_000, int(iters * 0.025 / max(dt, 1e-4))))

    t_start = time.time()
    t_end = t_start + seconds
    launches = bad_total = 0
    next_print = t_start
    while time.time() < t_end:
        if mon.abort_reason:
            break
        dt, bad = run_lcg(cuda, k, out, blocks, threads, iters)
        launches += 1
        bad_total += bad
        now = time.time()
        if now >= next_print:
            s = mon.last or {}
            log(f"   t={now - t_start:4.0f}s  T={fmt(s.get('temp'), '°C')}  P={fmt(s.get('power'), 'W')}"
                f"  SM={fmt(s.get('sm'), 'MHz')}  kihaszn.={fmt(s.get('util'), '%')}"
                f"  PCIe Gen{fmt(s.get('gen'))}x{fmt(s.get('width'))}  hibás: {bad_total}")
            next_print = now + 2
        time.sleep(dt * (1 - duty) / duty)

    stats = summarize(mon.window(t_start))
    log(f"   Összegzés: max {fmt(stats['temp_max'], ' °C')}, átlag {fmt(stats['power_avg'], ' W')}"
        f" / max {fmt(stats['power_max'], ' W')}, max SM {fmt(stats['sm_max'], ' MHz')},"
        f" throttle: {decode_reasons(stats['reasons'])}")
    if mon.abort_reason:
        result(name, "HIBA", f"VÉSZLEÁLLÍTÁS: {mon.abort_reason}")
        return False, stats
    if bad_total:
        result(name, "HIBA", f"{bad_total} hibás eredmény {launches} futásból")
        return False, stats
    result(name, "OK", f"{launches} kernelfutás, 0 hiba, max {fmt(stats['temp_max'], ' °C')}, "
                       f"max {fmt(stats['power_max'], ' W')}")
    return True, stats


# ---------------------------------------------------------------------------
# Fokozatos terhelésnövelés: FP32 FMA kernel, kaotikus leképezéssel
#   minden szál 8 független láncot számol: x -> x*x - 1.9 (fma.rn.f32)
#   A leképezés kaotikus (az adatbitek "véletlenszerűen" billegnek -> valós
#   fogyasztás), de determinisztikus: egyetlen hibás bit is eltérő végeredményt ad.
#   Ellenőrzés: (1) néhány szál bitpontosan CPU-n emulálva, (2) referencia-futás,
#   (3) minden terhelő futás minden szálát a referenciához hasonlítjuk.
# ---------------------------------------------------------------------------
HEAVY_CHAINS, HEAVY_UNROLL, HEAVY_THREADS = 8, 4, 256
HEAVY_NEG_C = -1.9


def heavy_ptx():
    ch, un = HEAVY_CHAINS, HEAVY_UNROLL
    L = [".version 7.0", ".target sm_70", ".address_size 64", "",
         ".visible .entry fma_heavy(.param .u64 fh_out, .param .u32 fh_iters, .param .f32 fh_negc)",
         "{",
         "    .reg .pred %p<2>;",
         "    .reg .b32  %r<10>;",
         f"    .reg .f32  %f<{ch + 3}>;",
         "    .reg .b64  %rd<4>;",
         "    ld.param.u64 %rd1, [fh_out];",
         "    ld.param.u32 %r1, [fh_iters];",
         "    ld.param.f32 %f0, [fh_negc];",
         "    cvta.to.global.u64 %rd1, %rd1;",
         "    mov.u32 %r2, %ctaid.x;",
         "    mov.u32 %r3, %ntid.x;",
         "    mov.u32 %r4, %tid.x;",
         "    mad.lo.u32 %r5, %r2, %r3, %r4;",
         "    and.b32 %r6, %r5, 1023;",
         "    shl.b32 %r6, %r6, 3;"]
    # kezdőérték: x_j = (kulcs*8 + j) * 2^-13 - 0.5   (pontosan ábrázolható)
    for j in range(ch):
        f = j + 1
        L += [f"    add.u32 %r7, %r6, {j};",
              f"    cvt.rn.f32.u32 %f{f}, %r7;",
              f"    mul.rn.f32 %f{f}, %f{f}, 0f39000000;",
              f"    add.rn.f32 %f{f}, %f{f}, 0fBF000000;"]
    L += ["    mov.u32 %r8, 0;", "FH_LOOP:", "    setp.ge.u32 %p1, %r8, %r1;", "    @%p1 bra FH_DONE;"]
    for _ in range(un):
        for j in range(ch):
            L.append(f"    fma.rn.f32 %f{j + 1}, %f{j + 1}, %f{j + 1}, %f0;")
    L += [f"    add.u32 %r8, %r8, {un};", "    bra.uni FH_LOOP;", "FH_DONE:"]
    s = ch + 1
    L.append(f"    mov.f32 %f{s}, %f1;")
    for j in range(1, ch):
        L.append(f"    add.rn.f32 %f{s}, %f{s}, %f{j + 1};")
    L += ["    mul.wide.u32 %rd2, %r5, 4;", "    add.u64 %rd3, %rd1, %rd2;",
          f"    st.global.f32 [%rd3], %f{s};", "    ret;", "}"]
    return "\n".join(L) + "\n"


# --- bitpontos FP32 emuláció diadikus racionális számokkal: érték = M * 2^K ---
def _dy(x):
    n, d = x.as_integer_ratio()
    return (n, -(d.bit_length() - 1))


def _rnd32(M, K):
    """Kerekítés FP32-re (round-to-nearest-even). None = +végtelen."""
    if M == 0:
        return (0, 0)
    A = -M if M < 0 else M
    E = A.bit_length() - 1 + K
    if E >= 128:
        return None
    lsb = max(E, -126) - 23
    if lsb <= K:
        return (M, K)
    sh = lsb - K
    q, r, half = A >> sh, A & ((1 << sh) - 1), 1 << (sh - 1)
    if r > half or (r == half and q & 1):
        q += 1
    return (q if M > 0 else -q, lsb)


def _add(a, b):
    if a is None or b is None:
        return None
    K = min(a[1], b[1])
    return ((a[0] << (a[1] - K)) + (b[0] << (b[1] - K)), K)


def heavy_emulate(key, iters, nc):
    xs = [((key * 8 + j) - 4096, -13) for j in range(HEAVY_CHAINS)]
    for _ in range(iters):
        nxt = []
        for x in xs:
            if x is None:
                nxt.append(None)
            else:
                t = _add((x[0] * x[0], 2 * x[1]), nc)
                nxt.append(_rnd32(*t))
        xs = nxt
    s = xs[0]
    for x in xs[1:]:
        t = _add(s, x)
        s = None if t is None else _rnd32(*t)
    if s is None:
        return 0x7F800000
    return struct.unpack("<I", struct.pack("<f", math.ldexp(s[0], s[1])))[0]


def run_heavy(cuda, f, out, blocks, iters, negc, expected):
    n = blocks * HEAVY_THREADS
    cuda.memset32(out, 0, n)
    t0 = time.perf_counter()
    cuda.launch(f, blocks, HEAVY_THREADS, c_uint64(out), c_uint32(iters), c_float(negc))
    cuda.sync()
    dt = time.perf_counter() - t0
    buf = ctypes.create_string_buffer(4 * n)
    cuda.dtoh(buf, out, 4 * n)
    if expected is None or buf.raw == expected:
        return dt, 0
    a, b = memoryview(buf.raw).cast("I"), memoryview(expected).cast("I")
    return dt, sum(1 for x, y in zip(a, b) if x != y)


def ramp_section(cuda, sms, mon, nvml, power, args, out):
    section("7. Fokozatos terhelésnövelés (tápellátás és hűtés ellenőrzése)")
    mod = cuda.load_ptx(heavy_ptx())
    f = cuda.function(mod, "fma_heavy")
    negc = struct.unpack("<f", struct.pack("<f", HEAVY_NEG_C))[0]
    nc = _dy(negc)

    # 1) bitpontos CPU-ellenőrzés kis futáson
    chk_iters = 2000
    run_heavy(cuda, f, out, 1024 // HEAVY_THREADS, chk_iters, negc, None)
    buf = (c_uint32 * 1024)()
    cuda.dtoh(buf, out, 4096)
    keys = [0, 1, 511, 512, 777, 1023]
    bad = [k for k in keys if buf[k] != heavy_emulate(k, chk_iters, nc)]
    if bad:
        result("FP32 FMA kernel (bitpontos CPU-ellenőrzés)", "HIBA", f"eltérés a(z) {bad} szálaknál")
        return
    result("FP32 FMA kernel (bitpontos CPU-ellenőrzés)", "OK",
           f"{len(keys)} szál x {HEAVY_CHAINS} lánc x {chk_iters} lépés bitre egyezik")

    # 2) kalibrálás ~40 ms-os kernelre, teljes kihasználtsággal
    blocks = sms * 8
    n = blocks * HEAVY_THREADS
    run_heavy(cuda, f, out, blocks, chk_iters, negc, None)
    dt, _ = run_heavy(cuda, f, out, blocks, chk_iters, negc, None)
    iters = int(chk_iters * 0.040 / max(dt, 1e-4)) // HEAVY_UNROLL * HEAVY_UNROLL
    iters = max(HEAVY_UNROLL, min(iters, 4_000_000))

    # 3) referencia (kétszer, determinizmus ellenőrzése)
    refs = []
    for _ in range(2):
        run_heavy(cuda, f, out, 1024 // HEAVY_THREADS, iters, negc, None)
        b = ctypes.create_string_buffer(4096)
        cuda.dtoh(b, out, 4096)
        refs.append(b.raw)
    if refs[0] != refs[1]:
        result("FP32 FMA referencia", "HIBA", "két azonos futás eltérő eredményt adott")
        return
    expected = refs[0] * (n // 1024)
    log(f"  Terhelő kernel: {blocks} blokk x {HEAVY_THREADS} szál, {iters} iteráció (~40 ms/futás)")

    mx = power.max / 1000 if power.max else None
    steps = sorted({min(float(s), mx) if mx else float(s) for s in args.ramp_steps.split(",") if s.strip()})
    log(f"  Lépcsők: {', '.join(f'{s:.0f} W' for s in steps)}; {args.ramp_seconds} s / lépcső; "
        f"vészleállítás: lépcső + {args.ramp_margin:.0f} W, {args.max_temp} °C, HW lassítás")

    t0 = time.time()
    time.sleep(5)
    idle = summarize(mon.window(t0))["power_avg"] or 45.0
    log(f"  Üresjárati fogyasztás: {idle:.1f} W")

    hw_limit_ok = None
    est_full = None
    duty = 0.2
    reached = None
    for target in steps:
        last = mon.last or {}
        if last.get("temp") is not None and last["temp"] >= args.max_temp - 5:
            result(f"Lépcső {target:.0f} W", "FIGYELEM",
                   f"nem indult: már {last['temp']} °C (határ {args.max_temp} °C)")
            break
        log("")
        log(f"  --- Lépcső: {target:.0f} W ---")
        if not args.no_power_limit and hw_limit_ok is not False:
            hw_limit_ok = power.set(target + 10)
            if hw_limit_ok:
                log(f"   HW teljesítménykorlát: {fmt(power.current_w(), ' W')}")
            else:
                log("   HW teljesítménykorlát nem állítható (rendszergazda kell) -> csak szoftveres szabályozás")
        mon.max_power = target + args.ramp_margin
        if est_full and est_full > idle + 5:
            duty = min(1.0, max(0.05, 0.85 * (target - idle) / (est_full - idle)))

        t_start = time.time()
        t_end = t_start + args.ramp_seconds
        next_ctl, next_print = t_start + 2, t_start
        launches = bad_total = 0
        while time.time() < t_end and not mon.abort_reason:
            dt, bad = run_heavy(cuda, f, out, blocks, iters, negc, expected)
            launches += 1
            bad_total += bad
            if bad:
                break
            if duty < 1.0:
                time.sleep(dt * (1 - duty) / duty)
            now = time.time()
            if now >= next_ctl:
                w = [s["power"] for s in mon.window(now - 2) if s["power"] is not None]
                if w:
                    p = sum(w) / len(w)
                    if p > idle + 3:
                        est_full = idle + (p - idle) / duty
                        d_new = (target - idle) / max(est_full - idle, 1.0)
                        duty = min(1.0, max(0.05, min(duty + 0.15, 0.5 * duty + 0.5 * d_new)))
                next_ctl = now + 2
            if now >= next_print:
                s = mon.last or {}
                log(f"   t={now - t_start:4.0f}s  cél={target:.0f}W  P={fmt(s.get('power'), 'W')}"
                    f"  kitöltés={duty * 100:3.0f}%  T={fmt(s.get('temp'), '°C')}  SM={fmt(s.get('sm'), 'MHz')}"
                    f"  hibás: {bad_total}")
                next_print = now + 3

        steady = mon.window(t_start + args.ramp_seconds / 2)
        st = summarize(steady)
        sm_vals = [s["sm"] for s in steady if s["sm"]]
        tail = mon.window(time.time() - 20)
        slope = None
        if len(tail) >= 2 and tail[-1]["temp"] is not None and tail[0]["temp"] is not None:
            slope = (tail[-1]["temp"] - tail[0]["temp"]) / max(tail[-1]["t"] - tail[0]["t"], 1) * 60
        log(f"   Állandósult szakasz: átlag {fmt(st['power_avg'], ' W')}, max {fmt(st['power_max'], ' W')}, "
            f"max {fmt(st['temp_max'], ' °C')} (trend {fmt(slope, ' °C/perc', 1)}), "
            f"SM {fmt(min(sm_vals) if sm_vals else None)}-{fmt(st['sm_max'], ' MHz')}, "
            f"throttle: {decode_reasons(st['reasons'])}")

        name = f"Lépcső {target:.0f} W"
        if mon.abort_reason:
            result(name, "HIBA", f"VÉSZLEÁLLÍTÁS: {mon.abort_reason}")
            break
        if bad_total:
            result(name, "HIBA", f"{bad_total} hibás eredmény (számítási hiba terhelés alatt!)")
            break
        notes = [f"{launches} futás, 0 hiba", f"átlag {fmt(st['power_avg'], ' W')}",
                 f"max {fmt(st['temp_max'], ' °C')}"]
        status = "OK"
        if st["power_avg"] is not None and st["power_avg"] < target * 0.9 and duty >= 0.99:
            notes.append(f"a kernel teljes kitöltéssel ennyit ér el (cél {target:.0f} W)")
        if slope is not None and slope > 3:
            notes.append(f"még melegszik ({slope:.1f} °C/perc)")
        if st["reasons"] & 0x20:
            status = "FIGYELEM"
            notes.append("SW termikus lassítás")
        if st["reasons"] & 0x4:
            notes.append("SW teljesítménykorlát aktív (várt)")
        result(name, status, ", ".join(notes))
        reached = st["power_avg"]

    mon.max_power = args.max_power
    if not args.no_power_limit and hw_limit_ok:
        power.set(args.power_limit)

    if reached is not None and not mon.abort_reason and not any(
            r[1] == "HIBA" and r[0].startswith("Lépcső") for r in results):
        result("Tápellátás terhelés alatt", "OK",
               f"~{reached:.0f} W átlagig stabil, power brake / HW lassítás nélkül")

    log("\n  Visszahűlés figyelése 30 s ...")
    for _ in range(3):
        time.sleep(10)
        s = mon.last or {}
        log(f"   T={fmt(s.get('temp'), ' °C')}  P={fmt(s.get('power'), ' W', 1)}")


def run_all_gpus():
    """Minden GPU tesztelése egymás után, külön folyamatban (külön napló, tiszta állapot)."""
    cuda = Cuda()
    cuda.check(cuda.cuInit(0), "cuInit")
    n = c_int()
    cuda.check(cuda.cuDeviceGetCount(byref(n)), "cuDeviceGetCount")
    base, skip = [], False
    for a in sys.argv[1:]:
        if skip:
            skip = False
            continue
        if a == "--gpu":
            skip = True
            continue
        if a.startswith("--gpu="):
            continue
        base.append(a)
    print(f"{n.value} GPU található, tesztelés egymás után.", flush=True)
    codes = []
    for i in range(n.value):
        print()
        print("#" * 70)
        print(f"#  GPU {i} / {n.value - 1}")
        print("#" * 70, flush=True)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), *base, "--gpu", str(i)])
        codes.append(r.returncode)
        if r.returncode not in (0, 1):  # pl. Ctrl+C
            break
    print()
    print("=" * 70)
    print(" ÖSSZESÍTÉS (minden GPU)")
    print("=" * 70)
    for i, c in enumerate(codes):
        print(f"  GPU {i}: {'RENDBEN' if c == 0 else 'HIBA / lásd napló'}")
    for i in range(len(codes), n.value):
        print(f"  GPU {i}: nem futott")
    sys.exit(0 if codes and all(c == 0 for c in codes) and len(codes) == n.value else 1)


def main():
    global log
    ap = argparse.ArgumentParser(description="Kíméletes Tesla V100 alapműködés-teszt")
    ap.add_argument("--mem-percent", type=float, default=90, help="a szabad VRAM hány %%-át tesztelje (alap: 90)")
    ap.add_argument("--mem-passes", type=int, default=2, help="VRAM-teszt menetek száma (alap: 2)")
    ap.add_argument("--load-seconds", type=int, default=30, help="egy terhelési szakasz hossza mp-ben (alap: 30)")
    ap.add_argument("--skip-load", action="store_true", help="terhelési szakaszok kihagyása")
    ap.add_argument("--max-temp", type=int, default=80, help="vészleállítási hőmérséklet °C (alap: 80)")
    ap.add_argument("--max-idle-temp", type=int, default=75, help="ennyi °C felett el sem indul (alap: 75)")
    ap.add_argument("--max-power", type=float, default=160, help="vészleállítási fogyasztás W (alap: 160)")
    ap.add_argument("--power-limit", type=float, default=150, help="beállított teljesítménykorlát W (alap: 150)")
    ap.add_argument("--no-power-limit", action="store_true", help="ne módosítsa a teljesítménykorlátot")
    ap.add_argument("--ramp", action="store_true", help="fokozatos terhelésnövelés a végén")
    ap.add_argument("--ramp-only", action="store_true",
                    help="csak alapellenőrzés + fokozatos terhelés (VRAM/PCIe/könnyű terhelés nélkül)")
    ap.add_argument("--ramp-steps", default="150,200,250", help="lépcsők W-ban (alap: 150,200,250)")
    ap.add_argument("--ramp-seconds", type=int, default=60, help="egy lépcső hossza mp-ben (alap: 60)")
    ap.add_argument("--ramp-margin", type=float, default=25,
                    help="vészleállítás a lépcső célja + ennyi W felett (alap: 25)")
    ap.add_argument("--gpu", default="0",
                    help="tesztelendő GPU sorszáma (0, 1, ...) vagy 'all' = mind egymás után (alap: 0)")
    args = ap.parse_args()
    if args.ramp_only:
        args.ramp = True
    if args.gpu.lower() in ("all", "mind", "a"):
        run_all_gpus()
        return
    try:
        gpu_index = int(args.gpu)
    except ValueError:
        ap.error(f"érvénytelen --gpu érték: {args.gpu}")

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_dir = os.path.dirname(os.path.abspath(__file__))
    log = Log(os.path.join(log_dir, f"gpu_alapteszt_gpu{gpu_index}_{stamp}.log"))
    log(f"Tesla V100 kíméletes alapteszt - GPU {gpu_index} - {datetime.datetime.now():%Y-%m-%d %H:%M:%S}")
    log(f"Vészhatárok: {args.max_temp} °C, {args.max_power:.0f} W; teljesítménykorlát cél: "
        f"{'nem módosul' if args.no_power_limit else f'{args.power_limit:.0f} W'}"
        + (f"; fokozatos terhelés: {args.ramp_steps} W" if args.ramp else ""))

    cuda = Cuda()
    nvml = None
    mon = None
    power = None
    out = None
    try:
        cuda.init(gpu_index)
        nvml = NVML(cuda.pci_bus_id())
        log(f"Tesztelt GPU: {gpu_index}. ({cuda.pci_bus_id()})")

        ok, before = precheck(nvml, args)
        if not ok:
            log("\nAz előzetes ellenőrzés hibát talált, a teszt nem folytatódik.")
            return

        power = PowerCtl(nvml)
        apply_power_limit(power, args)

        mon = Monitor(nvml, args.max_temp, args.max_power)
        mon.start()
        time.sleep(1.0)

        sms = device_info(cuda)

        mod = cuda.load_ptx(PTX)
        k = {"fill": cuda.function(mod, "fill_pattern"), "check": cuda.function(mod, "check_pattern"),
             "lcg": cuda.function(mod, "lcg_work")}
        result("PTX kernelek fordítása (JIT)", "OK", "fill_pattern, check_pattern, lcg_work")

        if not args.ramp_only:
            memory_test(cuda, k, sms, args, mon)
            if not mon.abort_reason:
                pcie_test(cuda, mon)

        out = cuda.alloc(4 * sms * 8 * HEAVY_THREADS)
        if not mon.abort_reason:
            compute_ok = compute_test(cuda, k, sms, out)
        else:
            compute_ok = False

        load_stats = []
        if args.skip_load or args.ramp_only:
            section("6. Könnyű terhelés")
            result("Könnyű terhelési szakaszok", "KIHAGYVA", "--skip-load" if args.skip_load else "--ramp-only")
        elif compute_ok and not mon.abort_reason:
            section("6. Könnyű terhelés (kitöltési tényezővel korlátozva, folyamatos figyeléssel)")
            t_idle = time.time()
            time.sleep(5)
            idle = summarize(mon.window(t_idle))
            log(f"  Üresjárati alapállapot: {fmt(idle['temp_max'], ' °C')}, {fmt(idle['power_avg'], ' W', 1)}")
            for name, blocks, threads, duty in (("Könnyű terhelés", sms, 128, 0.25),
                                                 ("Mérsékelt terhelés", sms * 2, 256, 0.5)):
                good, st = load_stage(cuda, k, out, mon, name, blocks, threads, duty, args.load_seconds)
                load_stats.append(st)
                if not good:
                    break
            log("\n  Visszahűlés figyelése 10 s ...")
            t_cool = time.time()
            time.sleep(10)
            cool = mon.window(t_cool)
            if cool:
                log(f"  Hőmérséklet a végén: {fmt(cool[-1]['temp'], ' °C')}, fogyasztás: {fmt(cool[-1]['power'], ' W', 1)}")

        if args.ramp:
            if compute_ok and not mon.abort_reason and not any(r[1] == "HIBA" for r in results):
                ramp_section(cuda, sms, mon, nvml, power, args, out)
            else:
                section("7. Fokozatos terhelésnövelés")
                result("Fokozatos terhelés", "KIHAGYVA", "korábbi hiba miatt nem indult")

        # --- Utóellenőrzés ---
        section("8. Utóellenőrzés")
        after_c, after_u = nvml.ecc(0, 0), nvml.ecc(1, 0)
        log(f"  ECC volatile javított: {fmt(before['ecc_vol_c'])} -> {fmt(after_c)}")
        log(f"  ECC volatile javíthatatlan: {fmt(before['ecc_vol_u'])} -> {fmt(after_u)}")
        if after_u is None and after_c is None:
            result("ECC a teszt alatt", "INFO", "ECC kikapcsolva, nem ellenőrizhető")
        elif after_u is not None and before["ecc_vol_u"] is not None and after_u > before["ecc_vol_u"]:
            result("ECC a teszt alatt", "HIBA", f"+{after_u - before['ecc_vol_u']} javíthatatlan hiba")
        elif after_c is not None and before["ecc_vol_c"] is not None and after_c > before["ecc_vol_c"]:
            result("ECC a teszt alatt", "FIGYELEM", f"+{after_c - before['ecc_vol_c']} javított (1 bites) hiba")
        else:
            result("ECC a teszt alatt", "OK", "nem keletkezett új ECC hiba")

        replay = nvml.uint("nvmlDeviceGetPcieReplayCounter")
        log(f"  PCIe replay számláló: {fmt(before['replay'])} -> {fmt(replay)}")
        if replay is not None and before["replay"] is not None:
            diff = replay - before["replay"]
            if diff > 100:
                result("PCIe jelminőség", "FIGYELEM",
                       f"+{diff} replay: adapter/riser/kábel jelminőségi gond lehet")
            else:
                result("PCIe jelminőség", "OK", f"+{diff} replay")

        allst = summarize(mon.samples)
        dev_max_gen = nvml.uint("nvmlDeviceGetGpuMaxPcieLinkGeneration")
        pcie_bw = PCIE_BW[0]
        if pcie_bw and pcie_bw > 8.5:
            result("PCIe link generáció", "OK",
                   f"mért {pcie_bw:.1f} GB/s csak Gen3 x16-tal érhető el (üresjáratban a link "
                   f"energiatakarékosan Gen{allst['gen_max']}-re vált, ez normális)")
        elif pcie_bw is not None and allst["gen_max"] and dev_max_gen and allst["gen_max"] < dev_max_gen:
            result("PCIe link generáció", "FIGYELEM",
                   f"terhelés alatt is max Gen{allst['gen_max']} (GPU Gen{dev_max_gen}-ra képes). "
                   f"Működik, de fele sávszélesség: adapter/riser vagy BIOS PCIe beállítás korlátozhatja.")
        elif pcie_bw is not None and allst["gen_max"]:
            result("PCIe link generáció", "OK", f"Gen{allst['gen_max']} x{allst['width_max']}")
        if allst["reasons"] & THROTTLE_HW_BAD:
            result("HW lassítás a teszt alatt", "HIBA", decode_reasons(allst["reasons"] & THROTTLE_HW_BAD))
        log(f"  Teljes futás alatt: max {fmt(allst['temp_max'], ' °C')}, max {fmt(allst['power_max'], ' W')}")

    except KeyboardInterrupt:
        log("\nMegszakítva (Ctrl+C).")
        result("Futás", "MEGSZAKÍTVA", "felhasználó által")
    except Exception as e:
        log(f"\nVÁRATLAN HIBA: {type(e).__name__}: {e}")
        result("Futás", "HIBA", f"{type(e).__name__}: {e}")
    finally:
        if mon:
            mon.stop()
        try:
            if out:
                cuda.free(out)
        except Exception:
            pass
        cuda.release()
        if power is not None:
            r = power.restore()
            if r is not None:
                log(f"\n  Teljesítménykorlát visszaállítva: {power.orig / 1000:.0f} W"
                    + ("" if r == 0 else f" - SIKERTELEN: {nvml.err(r)}"))
        if nvml:
            nvml.shutdown()

        section("ÖSSZEGZÉS")
        for name, status, detail in results:
            log(f"  [{status:^11}] {name}" + (f" - {detail}" if detail else ""))
        n_fail = sum(1 for r in results if r[1] in ("HIBA", "MEGSZAKÍTVA"))
        n_warn = sum(1 for r in results if r[1] == "FIGYELEM")  # INFO nem számít
        log("")
        if n_fail:
            log(f"  VÉGEREDMÉNY: HIBA ({n_fail} hiba, {n_warn} figyelmeztetés)")
        elif n_warn:
            log(f"  VÉGEREDMÉNY: MŰKÖDIK, {n_warn} figyelmeztetéssel")
        else:
            log("  VÉGEREDMÉNY: MINDEN RENDBEN")
        log(f"  Napló: {log.path}")
        log.close()
        sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
