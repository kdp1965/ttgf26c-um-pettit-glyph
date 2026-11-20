# Testbench for the Glyph VGA clock

[test.py](test.py) is the chip bench ([cocotb](https://docs.cocotb.org/en/stable/)): it checks the VGA sync timing, then
probes pixels of the face while it presses the buttons and changes the mode, colour and view.
A frame is 420000 clocks, so with Icarus (and at gate level) it stops after the first 30 frames;
with Verilator it runs to the end (`make -B SIM=verilator SIM_BUILD=sim_build/vl EXTRA_ARGS="-Wno-fatal --timing"`,
or `make test` one directory up). The waveform dump is off unless you add `WAVES=1`.

[unit/](unit) holds two plain Verilog benches (`make units` one directory up): `tb_clock.v` checks the
calendar against a model through a year, `tb_face.v` renders frames of the face to PPM files.

## How to run

To run the RTL simulation:

```sh
make -B
```

To run gatelevel simulation, first harden your project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`.

Then run:

```sh
make -B GATES=yes
```

If you wish to save the waveform in VCD format instead of FST format, edit tb.v to use `$dumpfile("tb.vcd");` and then run:

```sh
make -B FST=
```

This will generate `tb.vcd` instead of `tb.fst`.

## How to view the waveform file

Using GTKWave

```sh
gtkwave tb.fst tb.gtkw
```

Using Surfer

```sh
surfer tb.fst
```
