# Local flow for the Glyph tile (what the Tiny Tapeout GDS action does).
#
# Tools: the LibreLane nix shell (NIX_SHELL), the Tiny Tapeout support tools
# checked out in tt/ (git-ignored) with their own venv (.venv-tt, git-ignored),
# and PDK_ROOT holding gf180mcuD.
#     git clone https://github.com/TinyTapeout/tt-support-tools tt
#     make venv
#     make harden [TAG=name]        # runs/<TAG>/, log in harden-<TAG>.log
#     make synth  [TAG=name]        # synthesis only: area and cell counts
#     make art                      # macros/CALVIN/ from art/calvin.png (the chip art)
#     make units                    # the unit benches (test/unit)
#     make screenshots              # docs/screenshots/*.png from the frames `make units` rendered
#     make test                     # the chip bench at RTL, whole, with Verilator
#     make gl RUN=runs/<TAG>        # the chip bench on the hardened netlist
#     make promote RUN=runs/<TAG>   # local_build/ (what GitHub publishes) from a run
NIX_SHELL ?= $(HOME)/projects/tiny_tapeout/librelane/shell.nix
PDK_ROOT  ?= $(HOME)/projects/fossi
PYTHON    ?= python3.12
COCOTB    ?= $(HOME)/venvs/cocotb/bin
TAG       ?= wokwi
RUN       ?= runs/$(TAG)
TO        ?=
ifeq ($(IN_NIX_SHELL),)
RUN_SH = nix-shell $(NIX_SHELL) --run
else
RUN_SH = sh -c
endif
# tt_tool.py uses gitpython, which must find a native git (the nix one), and
# shells out to yowasp-yosys from its venv.
TT_PY = export GIT_PYTHON_GIT_EXECUTABLE=\$$(which git); export PATH=\"\$$PATH:$(CURDIR)/.venv-tt/bin\"; .venv-tt/bin/python
LIBRELANE = export PDK_ROOT=$(PDK_ROOT); python -m librelane --pdk-root $(PDK_ROOT) --pdk gf180mcuD

.PHONY: art venv config harden synth units screenshots test gl promote gui klayout

venv:
	$(PYTHON) -m venv .venv-tt
	.venv-tt/bin/python -m pip install --quiet --upgrade pip
	.venv-tt/bin/python -m pip install --quiet -r tt/requirements.txt

# Calvin (art/calvin.png, one pixel per 0.5 um of Metal4) at his place on the
# tile, and the keep-out cut under him: macros/CALVIN/.  The numbers are
# repeated in src/config.json's ROUTING_OBSTRUCTIONS.
art:
	$(RUN_SH) "python3 tools/chip_art.py --image art/calvin.png --origin 25.765 5.27 --keepout 25.2 3.92 56.3 43.12 --out macros/CALVIN"

# info.yaml + src/config.json -> src/user_config.json + src/config_merged.json
config:
	$(RUN_SH) "$(TT_PY) tt/tt_tool.py --create-user-config --pdk gf180mcuD"

# A tag that already has a run is overwritten.
harden: config
	mkdir -p runs/$(TAG)
	$(RUN_SH) "$(LIBRELANE) --run-tag $(TAG) --force-run-dir runs/$(TAG) --overwrite $(if $(TO),--to $(TO),) src/config_merged.json" 2>&1 | tee harden-$(TAG).log

synth:
	$(MAKE) harden TAG=synth-$(TAG) TO=Yosys.Synthesis

units:
	mkdir -p test/unit/out
	cd test/unit && iverilog -g2012 -o out/tb_clock ../../src/glyph_clock.v tb_clock.v && vvp out/tb_clock
	cd test/unit && iverilog -g2012 -o out/tb_face ../../src/glyph_face.v tb_face.v && vvp out/tb_face

# The frames tb_face.v rendered, as PNGs: one per frame, at the monitor's
# 640x480, and the two sheets the datasheet uses.
SHOTS = h_0120 m_0120 e_0120 h_0319 h_1200 e_1044 m_0621 m_0854pm e_0232pm e_0705 h_1111 m_date_0723 m_date_0723_nogrid d_1044 d_0705 d_1238 d_0926 d_date_0723 d_date_1231 d_date_0205
P2P = python3 test/unit/ppm2png.py
screenshots:
	mkdir -p docs/screenshots
	for s in $(SHOTS); do $(P2P) docs/screenshots/$$s.png test/unit/out/$$s.ppm; done
	$(P2P) docs/modes.png $(foreach s,h_0120 m_0120 e_0120,test/unit/out/$(s).ppm) --cols 3
	$(P2P) docs/examples.png $(foreach s,h_0319 e_1044 h_1200 m_0621,test/unit/out/$(s).ppm) --cols 2

# test/Makefile finds the sources through $(PWD), so these run from test/
test:
	cd test && PATH=$(COCOTB):$$PATH $(MAKE) -B SIM=verilator SIM_BUILD=sim_build/vl EXTRA_ARGS="-Wno-fatal --timing"

gl:
	cp $(RUN)/final/pnl/*.pnl.v test/gate_level_netlist.v
	cd test && PATH=$(COCOTB):$$PATH PDK_ROOT=$(PDK_ROOT) GATES=yes $(MAKE) -B

# The views the gds workflow publishes (custom_gds): GDS, LEF, powered netlist.
TOP = tt_um_pettit_glyph
promote:
	mkdir -p local_build/gds local_build/lef local_build/pnl
	cp $(RUN)/final/gds/$(TOP).gds local_build/gds/
	cp $(RUN)/final/lef/$(TOP).lef local_build/lef/
	cp $(RUN)/final/pnl/$(TOP).pnl.v local_build/pnl/
	cp $(RUN)/final/metrics.json local_build/

gui:
	$(RUN_SH) "openroad -gui -no_init -db $(firstword $(wildcard $(RUN)/final/odb/*.odb))"

klayout:
	$(RUN_SH) "klayout $(firstword $(wildcard $(RUN)/final/gds/*.gds))"
