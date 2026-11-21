#!/usr/bin/env python3
"""Worst slow-corner paths of a run, by the RTL names of their registers.

    python3 tools/timing_paths.py runs/<TAG> [period_ns]

A path that ends in a register loaded only on frame_tick and starts from a
register that itself changes only on frame_tick has a whole frame to settle;
those are marked "frame" and are not real limits on the pixel clock.
"""
import glob, re, sys
run = sys.argv[1]; period = float(sys.argv[2]) if len(sys.argv) > 2 else 39.72
rpt = open(sorted(glob.glob(run + '/*-openroad-stapostpnr/max_ss_125C_3v00/max.rpt'))[-1]).read()
pnl = open(glob.glob(run + '/final/pnl/*.pnl.v')[0]).read()
q = {}
for m in re.finditer(r'gf180mcu_fd_sc_mcu7t5v0__dff\w+ (\S+) \((.*?)\);', pnl, re.S):
    qq = re.search(r'\.Q\(([^)]*)\)', m.group(2)); q[m.group(1)] = qq.group(1).strip().lstrip('\\') if qq else '?'
FRAME = re.compile(r'^(hold|btn_prev|ui_s|btn|set_color|grid_on|view_date|mode|fast|face\.mode|color|digits|view_prev|fcnt|reveal|clock\.(h12|pm|m5|m1|mon|d5|d1|s5|s1))\b')
rows = []
for p in re.split(r'\nStartpoint: ', rpt)[1:]:
    s = p.split()[0]; e = re.search(r'Endpoint: (\S+)', p).group(1)
    arr = float(re.search(r'([\d.]+)\s+data arrival time', p).group(1))
    req = float(re.search(r'(-?[\d.]+)\s+data required time', p).group(1))
    clkp = [float(x) for x in re.findall(r'([\d.]+)\s+clock clk \(rise edge\)', p)]
    tgt = max(clkp) if clkp else 30.0
    need = arr - (req - tgt)          # the clock period this path needs
    s, e = q.get(s, s), q.get(e, e)
    rows.append((need, s, e, 'frame' if FRAME.match(s) and FRAME.match(e) else 'real'))
rows.sort(reverse=True)
for kind in ('real', 'frame'):
    sel = [r for r in rows if r[3] == kind]
    print(f'{kind}: {len(sel)} paths, worst needs {sel[0][0]:.2f} ns (period {period} ns)' if sel else f'{kind}: none')
    for need, s, e, _ in sel[:6]:
        print(f'   {need:6.2f} ns  {s:26s} -> {e}')
