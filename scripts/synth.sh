#!/usr/bin/env bash

set -e

echo "=========================================="
echo " ClearSense Yosys Synthesis"
echo "=========================================="

mkdir -p results/synthesis

echo ""
echo "------------------------------------------"
echo " Parallel FIR Architecture"
echo "------------------------------------------"

yosys -p "
    read_verilog -sv rtl/clearsense_parallel.sv;
    hierarchy -check -top clearsense_parallel;
    proc;
    opt;
    memory;
    opt;
    tee -o results/synthesis/parallel_stats.txt stat;
    tee -o results/synthesis/parallel_stats.json stat -json;
"

echo ""
echo "Parallel synthesis completed."

echo ""
echo "------------------------------------------"
echo " Shared-Multiplier FIR Architecture"
echo "------------------------------------------"

yosys -p "
    read_verilog -sv rtl/clearsense_shared.sv;
    hierarchy -check -top clearsense_shared;
    proc;
    opt;
    memory;
    opt;
    tee -o results/synthesis/shared_stats.txt stat;
    tee -o results/synthesis/shared_stats.json stat -json;
"

echo ""
echo "Shared synthesis completed."

echo ""
echo "=========================================="
echo " ClearSense synthesis completed"
echo "=========================================="
