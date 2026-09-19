IVERILOG = iverilog
VVP      = vvp

RTL = rtl/clearsense_parallel.sv rtl/clearsense_shared.sv
TB  = tb/tb_clearsense.sv

BUILD_DIR = build

.PHONY: all test clean synth analyze

all: test synth analyze

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

test: $(BUILD_DIR)
	@echo "=========================================="
	@echo " Running ClearSense RTL Regression"
	@echo "=========================================="

	@$(MAKE) run_test DATA_W=12 TAPS=4  SHARED=0
	@$(MAKE) run_test DATA_W=12 TAPS=8  SHARED=0
	@$(MAKE) run_test DATA_W=12 TAPS=16 SHARED=0

	@$(MAKE) run_test DATA_W=16 TAPS=4  SHARED=0
	@$(MAKE) run_test DATA_W=16 TAPS=8  SHARED=0
	@$(MAKE) run_test DATA_W=16 TAPS=16 SHARED=0

	@$(MAKE) run_test DATA_W=12 TAPS=4  SHARED=1
	@$(MAKE) run_test DATA_W=12 TAPS=8  SHARED=1
	@$(MAKE) run_test DATA_W=12 TAPS=16 SHARED=1

	@$(MAKE) run_test DATA_W=16 TAPS=4  SHARED=1
	@$(MAKE) run_test DATA_W=16 TAPS=8  SHARED=1
	@$(MAKE) run_test DATA_W=16 TAPS=16 SHARED=1

	@echo ""
	@echo "=========================================="
	@echo " All ClearSense configurations completed"
	@echo "=========================================="

run_test:
	@echo ""
	@echo "DATA_W=$(DATA_W) TAPS=$(TAPS) SHARED=$(SHARED)"

	$(IVERILOG) \
		-g2012 \
		-s tb_clearsense \
		-P tb_clearsense.DATA_W=$(DATA_W) \
		-P tb_clearsense.TAPS=$(TAPS) \
		-P tb_clearsense.USE_SHARED=$(SHARED) \
		-o $(BUILD_DIR)/sim_$(DATA_W)_$(TAPS)_$(SHARED) \
		$(RTL) $(TB)

	$(VVP) $(BUILD_DIR)/sim_$(DATA_W)_$(TAPS)_$(SHARED)

synth:
	@echo ""
	@echo "Synthesis scripts will be executed from scripts/synth.sh"

	@if [ -f scripts/synth.sh ]; then \
		bash scripts/synth.sh; \
	else \
		echo "Synthesis script not added yet."; \
	fi

analyze:
	@echo ""
	@echo "Sensor analysis will be executed from scripts/analyze.py"

	@if [ -f scripts/analyze.py ]; then \
		python3 scripts/analyze.py; \
	else \
		echo "Analysis script not added yet."; \
	fi

clean:
	rm -rf $(BUILD_DIR)

	@echo "Build directory cleaned."
