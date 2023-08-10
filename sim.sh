#!/bin/bash

iverilog -g2012 -c iverilog.cf -o sim $1 mcabus_t.v mcabus.v
vvp sim
