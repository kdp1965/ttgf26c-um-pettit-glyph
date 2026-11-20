# SPDX-FileCopyrightText: © 2026 Ken Pettit
# SPDX-License-Identifier: Apache-2.0
"""Chip bench for the Glyph VGA clock: sync timing, then pixels of the face
probed at known places while the time, mode, colour and view are changed."""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

PERIOD_NS = 40  # 25 MHz in simulation
PERIOD = PERIOD_NS * 1000  # in simulator steps (1 ps)
H_TOTAL, V_TOTAL = 800, 525
FRAME = H_TOTAL * V_TOTAL

# ui_in levels
DATE, MEDIUM, EASY = 0b0001_0000, 0b0010_0000, 0b0100_0000

BLACK, GREY = (0, 0, 0), (1, 1, 1)
CYAN, RED = (0, 3, 3), (3, 0, 0)

# Probe points (x, y); the face is centred on (320, 240).
BACKGROUND = (10, 240)
BODY = (320, 240 - 208)
STRAP = (300, 5)
BAR_TOP = (347, 5)          # PM marker
A_TOP = (320, 240 - 128)    # large hexagon, 12 o'clock edge
A_BOTTOM = (320, 240 + 128)
B_TOP = (320, 240 - 64)     # small hexagon, 12 o'clock edge
SPOKE_O3 = (320 + 185, 240)  # outer spokes
SPOKE_O9 = (320 - 185, 240)
SPOKE_O1 = (320 + 92, 240 - 160)
SPOKE_O5 = (320 + 92, 240 + 160)
SPOKE_I9 = (320 - 111, 240)  # inner spokes
SPOKE_I5 = (320 + 55, 240 + 96)
STRIPE_1 = (320 + 24, 240)   # centre stripes, rightmost first
STRIPE_2 = (320 + 8, 240)


class Screen:
    """Reads pixels by simulation time: pixel (x, y) of frame f is on the
    outputs in the clock period that starts t0 + (f*FRAME + y*800 + x) periods."""

    def __init__(self, dut):
        self.dut = dut
        self.t0 = None

    def frame_now(self):
        return (get_sim_time("step") - self.t0) // (FRAME * PERIOD)

    async def goto(self, frame, x, y):
        t = self.t0 + (frame * FRAME + y * H_TOTAL + x) * PERIOD + PERIOD // 2
        now = get_sim_time("step")
        assert t > now, "probe is in the past"
        await Timer(t - now, unit="step")

    async def frame(self, probes):
        """Samples the probes (in raster order) in the next whole frame."""
        f = self.frame_now() + 1
        out = {}
        for name, (x, y) in sorted(probes.items(), key=lambda kv: (kv[1][1], kv[1][0])):
            await self.goto(f, x, y)
            d = self.dut
            out[name] = (int(d.vga_r.value), int(d.vga_g.value), int(d.vga_b.value))
        return out

    async def pixel(self, xy):
        return (await self.frame({"p": xy}))["p"]

    async def web(self, xy):
        """An unlit segment is a checkerboard of grey and black."""
        x, y = xy
        got = await self.frame({"a": (x, y), "b": (x + 1, y)})
        return sorted(got.values()) == [BLACK, GREY]

    async def skip(self, frames):
        await self.goto(self.frame_now() + frames, 0, 0)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, PERIOD_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)  # a pixel takes two clocks to reach the outputs
    scr = Screen(dut)
    scr.t0 = get_sim_time("step")
    return scr


@cocotb.test()
async def test_sync(dut):
    """640x480 at 60 Hz: 800 clocks per line with a 96 clock pulse, 525 lines
    per frame with a 2 line pulse, both active low."""
    await start(dut)
    await FallingEdge(dut.vga_hsync)
    t_fall = get_sim_time("ns")
    await RisingEdge(dut.vga_hsync)
    assert get_sim_time("ns") - t_fall == 96 * PERIOD_NS
    await FallingEdge(dut.vga_hsync)
    assert get_sim_time("ns") - t_fall == H_TOTAL * PERIOD_NS

    await FallingEdge(dut.vga_vsync)
    t_fall = get_sim_time("ns")
    await RisingEdge(dut.vga_vsync)
    assert get_sim_time("ns") - t_fall == 2 * H_TOTAL * PERIOD_NS
    # Blanked during sync.
    assert (int(dut.vga_r.value), int(dut.vga_g.value), int(dut.vga_b.value)) == BLACK
    await FallingEdge(dut.vga_vsync)
    assert get_sim_time("ns") - t_fall == FRAME * PERIOD_NS
    assert int(dut.uio_oe.value) == 0


@cocotb.test()
async def test_face(dut):
    # A frame is 420000 clocks.  Verilator runs the whole test in a minute;
    # Icarus (the GitHub workflows, and every gate-level run) gets the first
    # 30 frames, which already cover reset, the draw-on, a button, the three
    # modes and the colour.
    short = os.environ.get("GATES") == "yes" or cocotb.SIM_NAME.lower().startswith("icarus")
    scr = await start(dut)

    async def press(buttons, held=0):
        """One press of the buttons in ui_in, the other inputs held."""
        dut.ui_in.value = held | buttons
        await scr.skip(2)
        dut.ui_in.value = held
        await scr.skip(2)

    # Frame 0: nothing is drawn on yet, only the body and the unlit web.
    got = await scr.frame({"bg": BACKGROUND, "body": BODY, "strap": STRAP, "bar": BAR_TOP})
    assert got == {"bg": BLACK, "body": GREY, "strap": GREY, "bar": BLACK}, got
    assert await scr.web(A_TOP)

    # The outer ring is drawn on by frame 16: 12:00, hard mode, cyan.
    await scr.skip(16)
    got = await scr.frame({"a": A_TOP, "o3": SPOKE_O3, "o9": SPOKE_O9, "bar": BAR_TOP})
    assert got == {"a": CYAN, "o3": CYAN, "o9": CYAN, "bar": BLACK}, got
    assert await scr.web(A_BOTTOM)

    # Hour button: 1:00.  Hard mode shows only the spokes at 9 and 5.
    await press(0b0000_0001)
    got = await scr.frame({"a": A_TOP, "o3": SPOKE_O3, "o9": SPOKE_O9, "o5": SPOKE_O5, "o1": SPOKE_O1})
    assert got["o9"] == CYAN and got["o5"] == CYAN, got
    assert CYAN not in (got["a"], got["o3"], got["o1"]), got

    # Medium joins them round the large hexagon.
    dut.ui_in.value = MEDIUM
    await scr.skip(2)
    got = await scr.frame({"a": A_TOP, "o1": SPOKE_O1})
    assert got["a"] == CYAN and got["o1"] != CYAN, got

    # Easy adds the spoke at 1; colour 1 is red.
    dut.ui_in.value = EASY
    dut.uio_in.value = 1
    await scr.skip(2)
    got = await scr.frame({"a": A_TOP, "o1": SPOKE_O1})
    assert got == {"a": RED, "o1": RED}, got

    if short:
        return

    # Eleven more hour presses: 12 PM, and the PM marker on the strap lights.
    for _ in range(11):
        assert await scr.pixel(BAR_TOP) == BLACK
        await press(0b0000_0001, EASY)
    # Two minute presses: 12:02.  By now the whole face is drawn on.
    await press(0b0000_0010, EASY)
    await press(0b0000_0010, EASY)
    assert scr.frame_now() >= 62
    got = await scr.frame({"bar": BAR_TOP, "a": A_TOP, "b": B_TOP, "s1": STRIPE_1, "s2": STRIPE_2,
                           "o3": SPOKE_O3})
    assert all(v == RED for v in got.values()), got

    # Date view: the face draws on again, then January (corner 1) and day 1.
    dut.ui_in.value = DATE
    await scr.skip(3)
    assert await scr.web(SPOKE_O9)
    # Day button four times meanwhile: the 5th, at the "05" corner.
    for _ in range(4):
        await press(0b0000_1000, DATE)
    await scr.skip(46)
    got = await scr.frame({"o9": SPOKE_O9, "o5": SPOKE_O5, "i9": SPOKE_I9, "i5": SPOKE_I5,
                           "b": B_TOP, "s1": STRIPE_1})
    assert got["o9"] == RED and got["o5"] == RED, got
    assert got["i9"] == RED and got["i5"] == RED, got
    assert RED not in (got["b"], got["s1"]), got
