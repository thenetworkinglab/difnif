#!/bin/bash

iverilog -o sim $1 mcabus_t.v mcabus.v
vvp sim
