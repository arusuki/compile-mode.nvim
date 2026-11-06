local helpers = require("spec.test_helpers")
local errors = require("compile-mode.errors")
local builtins = require("compile-mode.errors.matchers")
local candidates = require("compile-mode.errors.candidates")

describe("structured matcher candidates", function()
	before_each(helpers.setup_tests)

	it("rejects dense GNU errors before invoking unrelated native regexes", function()
		local config = require("compile-mode.config.internal")
		for _, name in ipairs({ "cucumber", "absoft", "borland", "ant", "cmake_info" }) do
			local matcher = vim.tbl_extend("force", {}, builtins[name])
			matcher._rx = {
				match_str = function()
					error("unexpected native match for " .. name)
				end,
			}
			config.error_regexp_table = { [name] = matcher }
			assert.is_nil(errors.parse("file.c:12:1: error: failure", 1), name)
		end
	end)

	it("retains all cucumber command and comment branches with capture parity", function()
		local config = require("compile-mode.config.internal")
		config.error_regexp_table = { cucumber = builtins.cucumber }
		for _, prefix in ipairs({ "cucumber ", "cucumber -p default ", "# ", "  # ", "step failed # " }) do
			for _, filename in ipairs({ "features/main.feature", "a b.feature", "测试.feature", "C:/test.feature" }) do
				local line = prefix .. filename .. ":12"
				local native = vim.fn.matchlist(line, builtins.cucumber.regex)
				assert.is_true(#native > 0, line)
				local parsed = assert(errors.parse(line, 1), line)
				assert.are.equal(native[2], parsed.filename.value)
				assert.are.equal(tonumber(native[3]), parsed.row.value)
			end
		end
	end)

	it("keeps optional absoft prefixes and borland severities", function()
		local config = require("compile-mode.config.internal")
		local variants = {
			absoft = {
				'Line\t12\tof\t"main.f":',
				'line 12 of "main.f":',
				'Error on Line 12 of "main.f":',
				'error on line 12 of "main.f":',
				'Warning on Line 12 of "main.f":',
				'warning on line 12 of "main.f":',
			},
			borland = { "Error E100 main.c 12: bad", "Warning W123 main.c 12: bad", "Error main.c 12)" },
		}
		for name, lines in pairs(variants) do
			config.error_regexp_table = { [name] = builtins[name] }
			for _, line in ipairs(lines) do
				assert.is_true(errors.parse(line, 1) ~= nil, line)
			end
		end
	end)

	it("does not filter a custom regex that replaces a builtin name", function()
		local config = require("compile-mode.config.internal")
		for _, name in ipairs({ "cucumber", "absoft", "borland", "ant", "cmake_info" }) do
			config.error_regexp_table = {
				[name] = { regex = [[^CUSTOM \(\S\+\) \([0-9]\+\)$]], filename = 1, row = 2 },
			}
			local parsed = assert(errors.parse("CUSTOM main.c 12", 1))
			assert.are.equal(name, parsed.group)
			assert.are.equal("main.c", parsed.filename.value)
		end
	end)

	it("conservatively retains folded prefixes independently of case options", function()
		for _, name in ipairs({ "cucumber", "absoft", "borland" }) do
			local line = require("spec.fixtures.matcher_witnesses")[name]
			assert.is_true(candidates.matches(line:upper(), builtins[name].regex))
			assert.is_true(candidates.matches(line:lower(), builtins[name].regex))
		end
		assert.is_true(candidates.matches("anything", [[\c^CUSTOM$]]))
	end)
end)
