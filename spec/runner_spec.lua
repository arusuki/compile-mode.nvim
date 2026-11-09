local assert = require("luassert")
local helpers = require("spec.test_helpers")
local s = require("scripts.support")
local errors = require("compile-mode.errors")

describe("queued compilation output", function()
	before_each(function()
		helpers.setup_tests()
		s.setup()
	end)

	-- Deliver callbacks in one turn, including process exit. This exercises
	-- queued work independently of OS pipe chunk sizes and scheduling luck.
	local function burst(chunks)
		local original = vim.fn.jobstart
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				for _, chunk in ipairs(chunks) do
					opts.on_stdout(987654, chunk)
				end
				opts.on_exit(987654, 0)
			end)
			return 987654
		end
		local ok, result = xpcall(function()
			return s.compile("queued test")
		end, debug.traceback)
		vim.fn.jobstart = original
		assert.is_true(ok, result)
		return result
	end

	it("publishes completion only after the final queued error is parsed and highlighted", function()
		local lines = {}
		for i = 1, 1025 do
			lines[i] = ("file.c:%d:1: error: failure"):format(i)
		end
		lines[#lines + 1] = ""
		local count_at_event, marks_at_event
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationFinished",
			callback = function(ev)
				count_at_event = vim.tbl_count(errors.error_list)
				local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
				marks_at_event = #vim.api.nvim_buf_get_extmarks(ev.data.bufnr, ns, 0, -1, {})
			end,
		})
		local ev = burst({ lines })
		assert.are.equal(1025, count_at_event)
		assert.are.equal(4100, marks_at_event)
		assert.are.equal(1025, errors.error_list[1029].row.value)
		assert.are.equal(1032, vim.api.nvim_buf_line_count(ev.bufnr))
	end)

	it("joins fragmented callback tails and preserves blank lines and unterminated output", function()
		local chunks = { { "pre" }, { "fix", "", "" } }
		for i = 1, 300 do
			chunks[#chunks + 1] = { "line " .. i, "" }
		end
		chunks[#chunks + 1] = { "last" }
		chunks[#chunks + 1] = { " fragment" }
		local ev = burst(chunks)
		local lines = vim.api.nvim_buf_get_lines(ev.bufnr, 4, -3, false)
		assert.are.equal("prefix", lines[1])
		assert.are.equal("", lines[2])
		for i = 1, 300 do
			assert.are.equal("line " .. i, lines[i + 2])
		end
		assert.are.equal("last fragment", lines[303])
		assert.are.equal(303, #lines)
	end)

	it("drains a real process before announcing completion", function()
		local ev = s.compile(s.command("scripts/producer.lua", "errors", "1025"))
		assert.are.equal(0, ev.code)
		assert.are.equal(1025, vim.tbl_count(errors.error_list))
		assert.are.equal(1025, errors.error_list[1029].row.value)
	end)

	it("removes completed job deletion handlers instead of accumulating them on recompile", function()
		local command = s.command("scripts/producer.lua", "plain", "1")
		local ev = s.compile(command)
		local before = #vim.api.nvim_get_autocmds({ event = "BufDelete", buffer = ev.bufnr })
		for _ = 1, 3 do
			s.compile(command, nil, true)
		end
		assert.are.equal(before, #vim.api.nvim_get_autocmds({ event = "BufDelete", buffer = ev.bufnr }))
	end)

	it("finishes and parses synchronous jobs without losing queued output", function()
		local finished
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationFinished",
			callback = function(ev)
				finished = ev.data
			end,
		})
		require("compile-mode").compile({
			args = s.command("scripts/producer.lua", "errors", "1025"),
			bang = true,
			smods = { silent = true },
		})
		assert.is_true(vim.wait(5000, function()
			return finished ~= nil
		end, 1))
		assert.are.equal(0, finished.code)
		assert.are.equal(1025, vim.tbl_count(errors.error_list))
	end)

	it("discards queued output on interruption before starting the next command", function()
		local parser = require("compile-mode.parser")
		local scan = parser.scan
		local interrupted, requested = false, false
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationInterrupted",
			callback = function()
				interrupted = true
			end,
		})
		---@diagnostic disable-next-line: duplicate-set-field
		parser.scan = function(buf, first, last)
			local result = scan(buf, first, last)
			if first >= 4 and not requested then
				requested = true
				vim.schedule(require("compile-mode").stop)
			end
			return result
		end
		require("compile-mode").compile({
			args = s.command("scripts/producer.lua", "errors", "10000"),
			smods = { silent = true },
		})
		local done = vim.wait(5000, function()
			return interrupted
		end, 1)
		parser.scan = scan
		assert.is_true(done)
		s.drain()
		local lines = vim.api.nvim_buf_get_lines(vim.g.compilation_buffer, -2, -1, false)
		assert.is_truthy(lines[1]:match("^Compilation interrupted"))
		local ev = s.compile(s.command("scripts/producer.lua", "plain", "10"))
		assert.are.equal(0, ev.code)
		assert.are.same({}, errors.error_list)
		assert.are.equal(17, vim.api.nvim_buf_line_count(ev.bufnr))
	end)
end)
