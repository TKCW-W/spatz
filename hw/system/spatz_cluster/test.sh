#!/bin/bash

# Tests to include (add your patterns here)
INCLUDE_PATTERNS=(“fdotp” "faxpy" "gemv" "fmatmul")

# Directory containing test executables
BUILD_DIR="sw/build/spatzBenchmarks"
VSIM_CMD="bin/spatz_cluster.vsim"

# Log directory
LOG_DIR="test_logs/kernel_logs_03_01_26"
mkdir -p "$LOG_DIR"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Starting Spatz test suite..."
echo "=============================="

# Counter for statistics
total=0
passed=0
failed=0 

# Find and run all test executables
for test_path in "$BUILD_DIR"/test-*; do
    # Skip .s files (assembly source files)
    if [ -f "$test_path" ] && [[ "$test_path" != *.s ]]; then
        test_name=$(basename "$test_path")

                # Check if test name matches any of the include patterns
        # If no patterns specified, run all tests
        match_found=false
        if [ ${#INCLUDE_PATTERNS[@]} -eq 0 ]; then
            match_found=true
        else
            for pattern in "${INCLUDE_PATTERNS[@]}"; do
                if [[ "$test_name" == *"$pattern"* ]]; then
                    match_found=true
                    break
                fi
            done
        fi
        
        # Skip if no match found
        if [ "$match_found" = false ]; then
            continue
        fi

        total=$((total + 1))
        
        echo -e "\n[${total}] Running: ${YELLOW}${test_name}${NC}"
        
        # Run simulation in batch mode (non-GUI, auto-exit)
        # Remove "-do 'run -all; quit -f'" if your vsim script already runs automatically
        $VSIM_CMD "$test_path" -do "run -all; quit -sim; quit -f" > "$LOG_DIR/${test_name}.log" 2>&1
        
        # Check exit status
        if [ $? -eq 0 ]; then
            echo -e "    ${GREEN}✓ PASSED${NC}"
            passed=$((passed + 1))
        else
            echo -e "    ${RED}✗ FAILED${NC}"
            failed=$((failed + 1))
        fi
    fi
done

# Summary
echo -e "\n=============================="
echo -e "Tests run: $total"
echo -e "${GREEN}Passed: $passed${NC}"
echo -e "${RED}Failed: $failed${NC}"
echo -e "Logs saved in: $LOG_DIR/"