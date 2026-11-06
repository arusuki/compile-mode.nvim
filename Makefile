FORMAT_FILES := lua/ spec/ plugin/ ftplugin/ scripts/

PYTHON ?= python3

fmt:
	@echo "===> Format"
	stylua $(FORMAT_FILES)

fmt-check:
	@echo "===> Check Formatting"
	stylua --check $(FORMAT_FILES)

test:
	@echo "===> Test"
	nvim --headless --clean \
		-u spec/configs/tests.vim \
		-c "PlenaryBustedDirectory spec/ {minimal_init = 'spec/configs/tests.vim', sequential = true}"

test-debug:
	@echo "===> Test (w/ Debug Logs)"
	TEST_DEBUG=true nvim --headless --clean \
		-u spec/configs/tests.vim \
		-c "PlenaryBustedDirectory spec/ {minimal_init = 'spec/configs/tests.vim', sequential = true}"

test/%:
	@echo "===> Test spec/$*_spec.lua"
	nvim --headless --clean \
		 -u spec/configs/tests.vim \
		 -c "PlenaryBustedDirectory spec/$*_spec.lua {minimal_init = 'spec/configs/tests.vim'}"

test-debug/%:
	@echo "===> Test spec/$*_spec.lua (w/ Debug Logs)"
	TEST_DEBUG=true nvim --headless --clean \
		 -u spec/configs/tests.vim \
		 -c "PlenaryBustedDirectory spec/$*_spec.lua {minimal_init = 'spec/configs/tests.vim'}"

typecheck:
	@echo "===> Typecheck"
	./typecheck.sh

setup-ci:
	@echo "===> Set Up CI"
	nvim --headless --clean -u spec/configs/ci.vim -c "q"

.PHONY: issues bench bench-long-lines

# Standalone assertions of issue expectations; exits nonzero for reproduced bugs.
issues:
	$(PYTHON) scripts/run_checks.py issues $(CHECK_ARGS)

# Separate from correctness tests: timing thresholds are machine-dependent.
bench:
	$(PYTHON) scripts/run_checks.py benchmark $(CHECK_ARGS)

# Fragmented long-line scaling, including work-count correctness assertions.
bench-long-lines:
	$(PYTHON) scripts/run_checks.py long_lines $(CHECK_ARGS)
