local helpers = require("spec.test_helpers")
local fast = require("compile-mode.errors.fast")
local utils = require("compile-mode.utils")
local regex = require("compile-mode.errors.matchers").gnu.regex

describe("canonical GNU capture extraction", function()
	before_each(helpers.setup_tests)

	it("extracts exact canonical prefixes without calling the regex engine", function()
		local rx = {
			match_str = function()
				error("canonical path must not repeat regex work")
			end,
		}
		for _, filename in ipairs({ "main.c", "./src/test-1.c", "_generated", "/tmp/a.c", "../1.c" }) do
			for _, position in ipairs({ "12", "012:003" }) do
				for _, prefix in ipairs({ "error", "Error", "warning", "Warning", "FutureWarning", "RuntimeWarning" }) do
					local line = filename .. ":" .. position .. ":   " .. prefix .. ": failure"
					assert.are.same(utils.matchlistpos(line, regex), fast.captures(line, regex, rx), line)
				end
			end
		end
	end)

	it("agrees with native captures on mixed grammar and ambiguous suffixes", function()
		local rx = vim.regex(regex)
		local filenames = {
			"main.c",
			"../x-2.c",
			"/tmp/a.b",
			"./12",
			"12.c",
			"é.c",
			"a b.c",
			"tool:main.c",
			"C:/main.c",
			"C:\\main.c",
			"main\n.c",
		}
		local positions = { "12", "001:03", "12.3", "12-14", "12:3-14.5", " 12:3", "12:3:4" }
		local suffixes = {
			"error: fail",
			"Error: fail",
			"warning: fail",
			"Warning: fail",
			"FutureWarning: fail",
			"RuntimeWarning: fail",
			"WARNING: fail",
			"errorish: fail",
			"note: fail",
			"error: file.c:12:3: warning",
			"error: 12",
			"error:\nmore",
			"",
			"12",
			"123",
			"\terror: fail",
		}
		for _, filename in ipairs(filenames) do
			for _, position in ipairs(positions) do
				for _, suffix in ipairs(suffixes) do
					for _, spaces in ipairs({ "", "   " }) do
						local line = filename .. ":" .. position .. ":" .. spaces .. suffix
						local actual = fast.captures(line, regex, rx)
						if actual then
							assert.are.same(utils.matchlistpos(line, regex, rx), actual, line)
						end
					end
				end
			end
		end
	end)

	it("retains the native matcher for noncanonical accepted shapes", function()
		local native = vim.regex(regex)
		local calls = 0
		local rx = {
			match_str = function(_, line)
				calls = calls + 1
				return native:match_str(line)
			end,
		}
		for _, suffix in ipairs({ "hello", "errorish", "warningly", "", "WARNING: fail" }) do
			local line = "main.c:12:3: " .. suffix
			assert.are.same(utils.matchlistpos(line, regex), fast.captures(line, regex, rx), line)
		end
		assert.are.equal(5, calls)
	end)
end)
