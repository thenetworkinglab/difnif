# Difnif
#
# Copyright (c) 2021 Eric Schlaepfer
# This work is licensed under CERN-OHL-S-2.0.
#

PROJ = difnif
IMAGES = difnif_top
SOURCES = difnif_top.v mcabus.v teensy.v sectorbuf.v
INCLUDES = version.vh
PIN_DEF =  difnif.pcf
DEVICE = hx8k
# Which board to build for:
#   make                    ThinkPad 700C board (POS registers bypassed)
#   make BOARD=ps2          72-pin board (pcb_formfactor) for PS/2 desktops such as
#                           the 50Z, 55SX and 70 (POS registers on)
#   make BOARD=p3           Rev P3 (docs/rev-p3-spec.md): FPGA-only, no Teensy, so
#                           always the processor build; its own pins (difnif_p3.pcf)
# Use the same BOARD for "make prog". Each board builds into its own folder.
BOARD = thinkpad
ifeq ($(BOARD),ps2)
DEFINES = -DMCA_USE_POS
else ifeq ($(BOARD),p3)
DEFINES = -DMCA_USE_POS -DDIFNIF_P3
PIN_DEF = difnif_p3.pcf
override CPU = 1
else ifneq ($(BOARD),thinkpad)
$(error BOARD must be thinkpad, ps2 or p3)
endif
# make PROBES=1 also copies bus signals onto the SD card pins for a scope
# (see the end of mcabus.v), building into build/<board>-probes. Not for releases.
ifeq ($(PROBES),1)
DEFINES += -DDIFNIF_PROBES
ODIR = build/$(BOARD)-probes
else
ODIR = build/$(BOARD)
endif
# make BOARD=ps2 CPU=1: the FPGA-only build, a processor in the Teensy's place
# (soc.v, firmware from ../fw), into build/<board>-cpu. docs/fpga-only.md.
ifeq ($(CPU),1)
DEFINES += -DDIFNIF_CPU
# Without this the processor's clock enables take the last global buffers,
# and ARB/-GNT and -TC (clocks for mcabus.v) go on ordinary routing
PNR_FLAGS += --no-promote-ce
# A fixed placement seed, so the same source gives the same image. Chosen
# for room on all three of the processor's 50 MHz clock (nextpnr's
# estimate), T22 and T54, which tools/timing_budget.py checks for the same
# seed (seeds 1-16 searched 2026-11-24 with oss-cad-suite 20260922; the
# clock reaches 50-54 MHz depending on the seed). Keep timing_budget.py's
# defaults in step.
ifeq ($(BOARD),p3)
PNR_SEED ?= 10
else
PNR_SEED ?= 4
endif
PNR_FLAGS += --seed $(PNR_SEED)
SOURCES += soc.v picorv32.v sdhost.v sdbridge.v
INCLUDES += fw.hex
ODIR = build/$(BOARD)$(if $(filter p3,$(BOARD)),,-cpu)$(if $(filter 1,$(PROBES)),-probes,)
endif
DEPS = $(addprefix $(ODIR)/,$(addsuffix .d,$(IMAGES)))

# Want to build report and main bin file
all: $(addprefix $(ODIR)/,$(addsuffix .rpt,$(IMAGES))) $(ODIR)/$(PROJ).binm

# removed %.v
$(ODIR)/%.json: $(SOURCES) $(INCLUDES) | $(ODIR)
	yosys $(DEFINES) -p 'synth_ice40 -top $(basename $(notdir $@)) -json $@ -blif test.blif' $(SOURCES) -E $(basename $(notdir $@)).d
	echo $@

$(ODIR)/%.asc: $(ODIR)/%.json $(PIN_DEF)
# fails if yosys tied a bidirectional pin to a constant, which would drive it
	python3 ../tools/check_inouts.py $<
# add -q to quiet lots of messages
	nextpnr-ice40 --$(DEVICE) --pcf $(PIN_DEF) --json $< --asc $@ --package tq144:4k $(PNR_FLAGS)
#	@echo nextpnr $< $@

$(ODIR)/%.bin: $(ODIR)/%.asc
	icepack $< $@
#	@echo icepack $< $@

# Combined multiboot image
$(ODIR)/%.binm: $(addprefix $(ODIR)/,$(addsuffix .bin, $(IMAGES)))
	icemulti -c -o $@ $^

$(ODIR)/%.rpt: $(ODIR)/%.asc
	icetime -d $(DEVICE) -mtr $@ $<
#	@echo icetime -d $(DEVICE) -mtr $@ $<

sim: $(ODIR)/$(PROJ)_t.vcd

$(ODIR)/$(PROJ)_t.vcd: $(PROJ)_t.v $(SOURCES) is61c5128_t.v

prog: $(ODIR)/$(PROJ).binm
#	iCEburn  -e -v -w  $<
	iceprog -p $<

sudo-prog: $(ODIR)/$(PROJ).bin
	@echo 'Executing prog as root!!!'
	iCEburn  -e -v -w  $<

clean:
	rm -f $(ODIR)/$(PROJ).blif $(ODIR)/$(PROJ).asc $(ODIR)/$(PROJ).bin $(ODIR)/$(PROJ).json $(ODIR)/$(PROJ).d $(ODIR)/*.bin $(ODIR)/*.binm $(ODIR)/*.rpt

reset:
	iceprog -t

%.vcd:
	iverilog $^ -o $(@:.vcd=.out)
	vvp $(@:.vcd=.out)

# Don't delete individual images
PRECIOUS: $(addsuffix .bin, $(addprefix $(ODIR)/,$(IMAGES)))

.PHONY: all prog clean reset

$(ODIR):
	mkdir -p $@

# Depsfile
-include $(DEPS)

# The processor build's firmware (CPU=1)
fw.hex: FORCE
	$(MAKE) -C ../fw
FORCE:
