# SPDX-FileCopyrightText: © 2026 Ken Pettit
# SPDX-License-Identifier: Apache-2.0
"""Chip bench for the Glyph VGA clock: sync timing, then pixels of the face
probed at known places while the time, mode, color and view are changed."""

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
SET_COLOR, GRID_OFF = 0b0000_0100, 0b0000_1000
BTN_A, BTN_B = 0b0000_0001, 0b0000_0010

BLACK, GRAY = (0, 0, 0), (1, 1, 1)
YELLOW, RED = (3, 3, 0), (3, 0, 0)

# Probe points (x, y); the face is centered on (320, 240).
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
STRIPE_1 = (320 + 24, 240)   # center stripes, rightmost first
STRIPE_2 = (320 + 8, 240)
TICK_1 = (320 - 80, 240 + 181)   # seconds ticks: 5 s, 10 s, 30 s
TICK_2 = (320 - 64, 240 + 181)
TICK_6 = (320, 240 + 181)
COLON = (480 + 9 * 8 + 4, 424 + 8 + 4)   # upper dot of the colon in the digits


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
        """An unlit segment is a checkerboard of gray and black."""
        x, y = xy
        got = await self.frame({"a": (x, y), "b": (x + 1, y)})
        return sorted(got.values()) == [BLACK, GRAY]

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
    assert int(dut.uio_oe.value) == 0x0F   # uio[3:0] is the readback


@cocotb.test()
async def test_face(dut):
    # A frame is 420000 clocks.  Verilator runs the whole test in a minute;
    # Icarus (the GitHub workflows, and every gate-level run) gets the first
    # 30 frames, which already cover reset, the draw-on, a button, the three
    # modes and the color.
    short = os.environ.get("GATES") == "yes" or cocotb.SIM_NAME.lower().startswith("icarus")
    scr = await start(dut)

    async def read():
        """The clock as the readback port gives it: (hour 0..23, minute,
        month 1..12, day)."""
        v = []
        for sel in range(7):
            dut.uio_in.value = sel << 4
            await Timer(3 * PERIOD, unit="step")
            v.append(int(dut.uio_out.value) & 0xF)
        return (v[0] + 12 * v[1], 5 * v[2] + v[3], v[4] or 12, 5 * v[5] + v[6])

    def ui(levels):
        dut.ui_in.value = levels

    async def press(buttons, held=0):
        """One press of the buttons in ui_in, the other inputs held."""
        ui(held | buttons)
        await scr.skip(2)
        ui(held)
        await scr.skip(2)

    # Frame 0: nothing is drawn on yet, only the body and the unlit web.
    got = await scr.frame({"bg": BACKGROUND, "body": BODY, "strap": STRAP, "bar": BAR_TOP})
    assert got == {"bg": BLACK, "body": GRAY, "strap": GRAY, "bar": BLACK}, got
    assert await read() == (0, 0, 1, 1)
    assert await scr.web(A_TOP)

    # The outer ring is drawn on by frame 16: 12:00, hard mode, yellow.
    await scr.skip(16)
    got = await scr.frame({"a": A_TOP, "o3": SPOKE_O3, "o9": SPOKE_O9, "bar": BAR_TOP})
    assert got == {"a": YELLOW, "o3": YELLOW, "o9": YELLOW, "bar": BLACK}, got
    assert await scr.web(A_BOTTOM)
    # No seconds tick is lit in the first five seconds.
    assert await scr.web(TICK_1) and await scr.web(TICK_6)

    # Hour button: 1:00.  Hard mode shows only the spokes at 9 and 5.
    await press(BTN_A)
    got = await scr.frame({"a": A_TOP, "o3": SPOKE_O3, "o9": SPOKE_O9, "o5": SPOKE_O5, "o1": SPOKE_O1})
    assert got["o9"] == YELLOW and got["o5"] == YELLOW, got
    assert YELLOW not in (got["a"], got["o3"], got["o1"]), got

    assert await read() == (1, 0, 1, 1)

    # Medium joins them round the large hexagon.
    ui(MEDIUM)
    await scr.skip(2)
    got = await scr.frame({"a": A_TOP, "o1": SPOKE_O1})
    assert got["a"] == YELLOW and got["o1"] != YELLOW, got

    # The time in digits in the lower right is on after reset, in whatever
    # mode.  With SET_COLOR, button B turns it off and on again, and leaves
    # the minutes alone.
    x, y = COLON
    got = await scr.frame({"dot": COLON, "gap": (x, y + 8)})
    assert got == {"dot": YELLOW, "gap": BLACK}, got
    await press(BTN_B, MEDIUM | SET_COLOR)
    ui(MEDIUM)
    assert await scr.pixel(COLON) == BLACK
    await press(BTN_B, MEDIUM | SET_COLOR)
    ui(MEDIUM)
    got = await scr.frame({"dot": COLON, "gap": (x, y + 8), "o1": SPOKE_O1, "s1": STRIPE_1})
    assert got["dot"] == YELLOW and got["gap"] == BLACK, got
    assert YELLOW not in (got["o1"], got["s1"]), got

    # Easy adds the spoke at 1.  With SET_COLOR, button A steps the color
    # to red and leaves the hour alone.
    await press(BTN_A, EASY | SET_COLOR)
    ui(EASY)
    got = await scr.frame({"a": A_TOP, "o1": SPOKE_O1, "o9": SPOKE_O9})
    assert got == {"a": RED, "o1": RED, "o9": RED}, got

    if short:
        return

    # Eleven more hour presses: 12 PM, and the PM marker on the strap lights.
    for _ in range(11):
        assert await scr.pixel(BAR_TOP) == BLACK
        await press(BTN_A, EASY)
    # Two minute presses: 12:02.  By now the whole face is drawn on.
    await press(BTN_B, EASY)
    await press(BTN_B, EASY)
    assert scr.frame_now() >= 62
    got = await scr.frame({"bar": BAR_TOP, "a": A_TOP, "b": B_TOP, "s1": STRIPE_1, "s2": STRIPE_2,
                           "o3": SPOKE_O3})
    assert all(v == RED for v in got.values()), got

    assert await read() == (12, 2, 1, 1)

    # Date view: the face draws on again, then January (corner 1) and day 1.
    ui(DATE)
    await scr.skip(3)
    assert await scr.web(SPOKE_O9)
    # Button B is the day here; four times meanwhile: the 5th, at the "05" corner.
    for _ in range(4):
        await press(BTN_B, DATE)
    await scr.skip(46)
    got = await scr.frame({"o9": SPOKE_O9, "o5": SPOKE_O5, "i9": SPOKE_I9, "i5": SPOKE_I5,
                           "b": B_TOP, "s1": STRIPE_1})
    assert got["o9"] == RED and got["o5"] == RED, got
    assert got["i9"] == RED and got["i5"] == RED, got
    assert RED not in (got["b"], got["s1"]), got

    # Button A is the month here: February, on the flat side at 2.
    await press(BTN_A, DATE)
    got = await scr.frame({"a": A_TOP, "o9": SPOKE_O9, "i9": SPOKE_I9})
    assert got["a"] == RED and got["o9"] != RED and got["i9"] == RED, got

    assert await read() == (12, 2, 2, 5)

    # Grid off input high: the unlit segments go, the lit ones and the body stay.
    assert await scr.web(A_BOTTOM)
    ui(DATE | GRID_OFF)
    await scr.skip(2)
    x, y = A_BOTTOM
    got = await scr.frame({"w0": (x, y), "w1": (x + 1, y), "a": A_TOP, "body": BODY})
    assert got == {"w0": BLACK, "w1": BLACK, "a": RED, "body": GRAY}, got

    # Back in the time view the buttons did not move the clock: still 12:02 PM.
    ui(EASY)
    await scr.skip(64)
    got = await scr.frame({"bar": BAR_TOP, "a": A_TOP, "b": B_TOP, "s2": STRIPE_2, "o3": SPOKE_O3})
    assert all(v == RED for v in got.values()), got

    # Both buttons together: the time goes back to 12:00 AM.  The color is
    # still red.
    await press(BTN_A | BTN_B, EASY)
    t_clear = scr.frame_now()
    got = await scr.frame({"bar": BAR_TOP, "a": A_TOP, "b": B_TOP, "s2": STRIPE_2, "o3": SPOKE_O3})
    assert got["bar"] == BLACK and got["s2"] != RED, got
    assert got["a"] == RED and got["b"] == RED and got["o3"] == RED, got

    # That left the date alone: still 5 February.
    ui(DATE)
    await scr.skip(64)
    got = await scr.frame({"a": A_TOP, "o9": SPOKE_O9, "i9": SPOKE_I9, "i5": SPOKE_I5})
    assert got["a"] == RED and got["o9"] != RED, got
    assert got["i9"] == RED and got["i5"] == RED, got

    # Both buttons in the date view: 1 January.
    await press(BTN_A | BTN_B, DATE)
    got = await scr.frame({"a": A_TOP, "o9": SPOKE_O9, "o5": SPOKE_O5, "b": B_TOP, "s1": STRIPE_1,
                           "i5": SPOKE_I5})
    assert got["o9"] == RED and got["o5"] == RED and got["b"] == RED and got["s1"] == RED, got
    assert RED not in (got["a"], got["i5"]), got

    assert await read() == (0, 0, 1, 1)

    # Digits in the date view: a slash where the colon was.
    x, y = COLON
    got = await scr.frame({"slash": (x + 8, y - 8), "colon": COLON})
    assert got == {"slash": RED, "colon": BLACK}, got
    # Button B with SET_COLOR again turns them off, and does not move the day.
    await press(BTN_B, DATE | SET_COLOR)
    ui(DATE)
    got = await scr.frame({"slash": (x + 8, y - 8), "s1": STRIPE_1})
    assert got["slash"] == BLACK and got["s1"] == RED, got

    # The seconds ticks: the time was cleared at the last press of both in
    # the time view; five seconds (300 frames) after it the first tick lights.
    assert await scr.web(TICK_1)
    await scr.goto(t_clear + 302, 0, 0)
    got = await scr.frame({"t1": TICK_1, "t2": TICK_2})
    assert got["t1"] == RED and got["t2"] != RED, got
