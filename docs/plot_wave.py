#!/usr/bin/env python3
"""Render a simple waveform PNG from the simulator's VCD file.

Usage: python3 docs/plot_wave.py build/apb_slave.vcd docs/waveform.png [t_start_ns] [t_end_ns]

This is only a convenience for the README. For real debugging use GTKWave or
Surfer (open build/apb_slave.vcd).
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

vcd_path = sys.argv[1]
out_png = sys.argv[2]
t0 = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
t1 = float(sys.argv[4]) if len(sys.argv) > 4 else 300.0

# signals to show: (name in tb scope, label, is_bus)
SHOW = [
    ("pclk", "PCLK", False),
    ("presetn", "PRESETn", False),
    ("psel", "PSEL", False),
    ("penable", "PENABLE", False),
    ("pwrite", "PWRITE", False),
    ("paddr", "PADDR", True),
    ("pwdata", "PWDATA", True),
    ("prdata", "PRDATA", True),
    ("pready", "PREADY", False),
    ("pslverr", "PSLVERR", False),
    ("phase", "phase (0=IDLE 1=SETUP 2=ACCESS)", True),
]

# ---- minimal VCD parser ----
ids = {}          # id code -> (name, width)
scope = []
changes = {}      # name -> list of (time_ns, value_str)
want = {n for n, _, _ in SHOW}
time_ns = 0.0
timescale_ps = 1.0
with open(vcd_path) as f:
    in_defs = True
    toks_iter = iter(f.read().split("\n"))
    for line in toks_iter:
        line = line.strip()
        if not line:
            continue
        if in_defs:
            if line.startswith("$timescale"):
                body = line
                while "$end" not in body:
                    body += " " + next(toks_iter).strip()
                body = body.replace("$timescale", "").replace("$end", "").strip()
                num = int("".join(c for c in body if c.isdigit()))
                unit = "".join(c for c in body if c.isalpha())
                timescale_ps = num * {"fs": 1e-3, "ps": 1, "ns": 1e3, "us": 1e6}[unit]
            elif line.startswith("$scope"):
                scope.append(line.split()[2])
            elif line.startswith("$upscope"):
                scope.pop()
            elif line.startswith("$var"):
                p = line.split()
                width, code, name = int(p[2]), p[3], p[4]
                # keep only top-level tb signals, plus dut.phase
                if (len(scope) == 1 and name in want) or (scope[-1] == "dut" and name == "phase"):
                    ids[code] = (name, width)
                    changes.setdefault(name, [])
            elif line.startswith("$enddefinitions"):
                in_defs = False
            continue
        if line.startswith("#"):
            time_ns = int(line[1:]) * timescale_ps / 1000.0
        elif line[0] in "01xzXZ" and len(line) > 1 and line[1:] in ids:
            name = ids[line[1:]][0]
            changes[name].append((time_ns, line[0]))
        elif line[0] == "b":
            val, code = line[1:].split()
            if code in ids:
                changes[ids[code][0]].append((time_ns, val))


def bus_to_text(v):
    if any(c in v for c in "xzXZ"):
        return "x"
    return f"{int(v, 2):X}"


fig, axes = plt.subplots(len(SHOW), 1, figsize=(14, 7.5), sharex=True)
for ax, (name, label, is_bus) in zip(axes, SHOW):
    ev = changes.get(name, [])
    ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=8)
    ax.set_yticks([])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    if not ev:
        continue
    if not is_bus:
        xs, ys = [], []
        for i, (t, v) in enumerate(ev):
            val = 1 if v == "1" else 0
            if xs:
                xs.append(t); ys.append(ys[-1])
            xs.append(t); ys.append(val)
        xs.append(t1); ys.append(ys[-1])
        ax.step(xs, ys, where="post", color="tab:blue", lw=1.3)
        ax.set_ylim(-0.3, 1.3)
    else:
        for i, (t, v) in enumerate(ev):
            tn = ev[i + 1][0] if i + 1 < len(ev) else t1
            if tn < t0 or t > t1:
                continue
            a, b = max(t, t0), min(tn, t1)
            ax.fill_between([a, b], 0, 1, color="#dbe9f6", ec="tab:blue", lw=0.8)
            if b - a > 8:
                ax.text((a + b) / 2, 0.5, bus_to_text(v), ha="center", va="center", fontsize=7)
        ax.set_ylim(-0.1, 1.1)
axes[-1].set_xlim(t0, t1)
axes[-1].set_xlabel("time (ns)")
fig.suptitle("AMBA APB slave - write then read transfers", fontsize=11)
fig.tight_layout()
fig.savefig(out_png, dpi=140)
print("wrote", out_png)
