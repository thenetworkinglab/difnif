# Difnif
#
# Copyright (c) 2021 Eric Schlaepfer
# This work is licensed under CERN-OHL-S-2.0.
#

PROJ = difnif
IMAGES = difnif_top
SOURCES = difnif_top.v mcabus.v teensy.v
PIN_DEF =  difnif.pcf
DEVICE = hx8k
# Which board to build for:
#   make                    ThinkPad 700C board (POS registers bypassed)
#   make BOARD=ps2          72-pin board (pcb_formfactor) for PS/2 desktops such as
#                           the 50Z, 55SX and 70 (POS registers on)
# Use the same BOARD for "make prog". Each board builds into its own folder.
BOARD = thinkpad
ifeq ($(BOARD),ps2)
DEFINES = -DMCA_USE_POS
else ifneq ($(BOARD),thinkpad)
$(error BOARD must be thinkpad or ps2)
endif
ODIR = build/$(BOARD)
DEPS = $(addprefix $(ODIR)/,$(addsuffix .d,$(IMAGES)))

# Want to build report and main bin file
all: $(addprefix $(ODIR)/,$(addsuffix .rpt,$(IMAGES))) $(ODIR)/$(PROJ).binm

# removed %.v
$(ODIR)/%.json: $(SOURCES) | $(ODIR)
	yosys $(DEFINES) -p 'synth_ice40 -top $(basename $(notdir $@)) -json $@ -blif test.blif' $(SOURCES) -E $(basename $(notdir $@)).d
	echo $@

$(ODIR)/%.asc: $(ODIR)/%.json $(PIN_DEF)
# add -q to quiet lots of messages
	nextpnr-ice40 --$(DEVICE) --pcf $(PIN_DEF) --json $< --asc $@ --package tq144:4k
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
