local assert = require("luassert")
local helpers = require("spec.test_helpers")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local parser = require("compile-mode.parser")
local state = require("compile-mode.state")
local fast = require("compile-mode.errors.fast")
local builtin = require("compile-mode.errors.matchers").gnu

local function drain()
	local done = false
	vim.schedule(function()
		done = true
	end)
	assert.is_true(vim.wait(1000, function()
		return done
	end, 1))
end

describe("bounded parser work", function()
	local buf
	before_each(function()
		helpers.setup_tests()
		state.reset()
		buf = vim.api.nvim_create_buf(false, true)
	end)

	it("retains oversized text while skipping all parser matchers", function()
		local config = require("compile-mode.config.internal")
		assert.are.equal(65536, config.max_parse_line_length)
		local line = "file.c:12:1: error: " .. string.rep("x", 65536)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line, string.rep("x", 1048576) .. ":" })
		local result = parser.scan(buf, 0, -1)
		assert.is_nil(errors.parse(line, 1))
		assert.are.same({}, errors.error_list)
		assert.are.equal(0, #result)
		assert.are.equal(line, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
	end)

	it("uses an inclusive byte threshold and allows disabling it for custom matchers", function()
		local config = require("compile-mode.config.internal")
		config.max_parse_line_length = 20
		config.error_regexp_table = { custom = { regex = [[^CUSTOM \(.\+\)$]], filename = 1 } }
		local line = "CUSTOM " .. string.rep("x", 13)
		assert(errors.parse(line, 1))
		assert.is_nil(errors.parse(line .. "x", 1))
		config.max_parse_line_length = 0
		assert(errors.parse(line .. string.rep("x", 65536), 1))
	end)

	it("skips long directory transitions and command highlights without truncating them", function()
		local config = require("compile-mode.config.internal")
		config.max_parse_line_length = 16
		vim.api.nvim_buf_set_lines(
			buf,
			0,
			-1,
			false,
			{ "make: Entering directory '/very/long/path'", "make[123]: building target" }
		)
		local result = parser.scan(buf, 0, -1)
		assert.are.same({}, require("compile-mode.dir").dir_changes)
		assert.are.equal(0, #result)
		config.max_parse_line_length = 0
		result = parser.scan(buf, 0, -1)
		assert.are.equal(vim.fn.fnamemodify("/very/long/path", ":p:h"), require("compile-mode.dir").dir_changes[1])
		assert.is_true(#result > 0)
	end)

	it("refreshes status only when counts or job status change", function()
		vim.g.compile_job_id, vim.g.compilation_exit_code = nil, nil
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain output" })
		parser.parse(buf, 0, -1)
		drain()
		local redraws = 0
		local redrawstatus = vim.cmd.redrawstatus
		vim.cmd.redrawstatus = function()
			redraws = redraws + 1
		end
		local ok, err = pcall(function()
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(0, redraws)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "main.c:2: error: failure" })
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(1, redraws)
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(1, redraws)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "main.c:3: warning: failure" })
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(2, redraws)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain output" })
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(3, redraws)
			vim.g.compile_job_id = 123
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(4, redraws)
			vim.g.compile_job_id, vim.g.compilation_exit_code = nil, 0
			parser.parse(buf, 0, -1)
			drain()
			assert.are.equal(5, redraws)
		end)
		vim.cmd.redrawstatus = redrawstatus
		vim.g.compile_job_id, vim.g.compilation_exit_code = nil, nil
		assert.is_true(ok, err)
	end)
end)

describe("native-compatible capture shortcuts", function()
	before_each(helpers.setup_tests)

	it("agrees with native GNU capture ranges across filenames, positions and messages", function()
		local rx = vim.regex(builtin.regex)
		local filenames = {
			"main.c",
			"src/file.lua",
			"./123",
			"123.c",
			"file name.c",
			"C:\\file.c",
			"C:/file.c",
			"pkg:name.c",
			"é.c",
			"_generated",
		}
		local positions = { "1", "12:3", "12.3", "12-13", "12-13.4", "12:3-14.5", "012:003", " 12:3" }
		local messages = {
			"",
			" error: bad",
			" Error: bad",
			" warning: bad",
			" Warning: bad",
			" WARNING: bad",
			" FutureWarning: bad",
			" RuntimeWarning: bad",
			" note: bad",
			" Note: bad",
			"info",
			"information",
			" matching text",
			"match:12:text",
			"12abc",
			"123",
			"12",
			"\twarning",
		}
		for _, filename in ipairs(filenames) do
			for _, position in ipairs(positions) do
				for _, message in ipairs(messages) do
					local line = filename .. ":" .. position .. ":" .. message
					local expected = utils.matchlistpos(line, builtin.regex, rx)
					local actual = fast.captures(line, builtin.regex, rx)
					if actual then
						assert.are.same(expected, actual, line)
					end
				end
			end
		end
	end)

	it("keeps the general extractor when ignorecase affects native captures", function()
		local previous = vim.o.ignorecase
		vim.o.ignorecase = true
		local result = fast.captures("main.c:12:WARNING: failure", builtin.regex, vim.regex(builtin.regex))
		vim.o.ignorecase = previous
		assert.is_nil(result)
	end)

	it("falls back for custom regexes even when they use the GNU matcher name", function()
		local config = require("compile-mode.config.internal")
		config.error_regexp_table = { gnu = { regex = [[^CUSTOM \(\S\+\)$]], filename = 1 } }
		assert.are.equal("main.c", errors.parse("CUSTOM main.c", 1).filename.value)
	end)

	it("preserves all ASCII and Unicode command-prefix ranges", function()
		local pattern = "^\\([[:alnum:]_/.+-]\\+\\)\\%(\\[\\([0-9]\\+\\)\\]\\)\\?[ \t]*:"
		for _, name in ipairs({ "make", "make-1.2", "./make++", "cmake_build", "échec", "编译", "!invalid", "" }) do
			for _, suffix in ipairs({
				": build",
				"[12]: build",
				"[012] \t: build",
				" [12]: build",
				"[abc]: build",
				"::",
			}) do
				local line = name .. suffix
				local captures = utils.matchlistpos(line, pattern)
				local expected = {}
				if captures[1] then
					expected[1] = { "CompileModeCommandOutput", 1, captures[1] }
				end
				if captures[3] then
					expected[2] = { "CompileModeMessageRow", 1, captures[3] }
				end
				assert.are.same(expected, utils.match_command_ouput(line, 1), line)
			end
		end
	end)
end)
