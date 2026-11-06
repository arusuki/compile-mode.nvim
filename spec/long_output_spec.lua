local assert = require("luassert")
local helpers = require("spec.test_helpers")
local s = require("scripts.support")
local ansi = require("compile-mode.ansi")
local errors = require("compile-mode.errors")

local jobstart, jobstop, writer
local callbacks, finished, writes, bytes, stopped, next_job

local function drain()
	local done = false
	vim.defer_fn(function()
		vim.defer_fn(function()
			done = true
		end, 0)
	end, 0)
	assert.is_true(vim.wait(5000, function()
		return done
	end, 1))
	s.drain()
end

local function emit(data)
	callbacks.on_stdout(987654, data)
	drain()
end

local function stderr(data)
	callbacks.on_stderr(987654, data)
	drain()
end

local function foreground(row, column)
	local ns = vim.api.nvim_create_namespace("compile-mode-BaleiaColors")
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(finished.bufnr, ns, 0, -1, { details = true })) do
		local detail = assert(mark[4])
		if mark[2] == row + 4 and mark[3] <= column and detail.end_col > column then
			return vim.api.nvim_get_hl(0, { name = detail.hl_group, link = false }).fg
		end
	end
end

local function colors()
	local config = require("compile-mode.config.internal")
	config.ansi_color = { kind = "render", baleia_options = { colors = { [1] = "#ab1234", [4] = "#1234ab" } } }
	return config
end

local function finish()
	callbacks.on_exit(987654, 0)
	assert.is_true(vim.wait(5000, function()
		return finished ~= nil
	end, 1))
	drain()
	return vim.api.nvim_buf_get_lines(finished.bufnr, 4, -3, false)
end

describe("long unfinished compilation output", function()
	before_each(function()
		helpers.setup_tests()
		s.setup()
		callbacks, finished, writes, bytes, stopped = nil, nil, 0, 0, 0
		next_job = 987654
		jobstart, jobstop, writer = vim.fn.jobstart, vim.fn.jobstop, ansi.buf_set_lines
		vim.fn.jobstart = function(_, opts)
			callbacks = opts
			next_job = next_job + 1
			return next_job
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.jobstop = function()
			stopped = stopped + 1
			return 1
		end
		---@diagnostic disable-next-line: duplicate-set-field
		ansi.buf_set_lines = function(buf, start, end_, lines, replay, context)
			writes = writes + 1
			for _, line in ipairs(lines) do
				bytes = bytes + #line
			end
			return writer(buf, start, end_, lines, replay, context)
		end
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationFinished",
			callback = function(ev)
				finished = ev.data
			end,
		})
	end)

	after_each(function()
		vim.fn.jobstart, vim.fn.jobstop, ansi.buf_set_lines = jobstart, jobstop, writer
	end)

	local function start()
		callbacks = nil
		require("compile-mode").compile({ args = "long output", smods = { silent = true } })
		assert.is_true(vim.wait(5000, function()
			return callbacks ~= nil
		end, 1))
	end

	it("bounds actual writer bytes across separately drained callbacks and flushes on exit", function()
		start()
		local prefix, chunk = string.rep("x", 65536), string.rep("y", 256)
		emit({ prefix })
		for _ = 1, 1000 do
			emit({ chunk })
		end
		local expected = prefix .. string.rep(chunk, 1000)
		assert.are.same({ expected }, finish())
		assert.is_true(writes <= 4, "writer was called " .. writes .. " times")
		assert.is_true(bytes < 3 * #expected, "ANSI/buffer work must not replay every prefix")
	end)

	it("parses and highlights the final deferred suffix before the completion event", function()
		local config = require("compile-mode.config.internal")
		config.max_parse_line_length = 0
		config.error_regexp_table = { custom = { regex = [[^\(file.c\):\([0-9]\+\):.*END$]], filename = 1, row = 2 } }
		start()
		emit({ "file.c:1:" .. string.rep("x", 65536) })
		emit({ "END" })
		assert.is_nil(errors.error_list[5])
		local at_event
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationFinished",
			callback = function(ev)
				local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
				at_event = { errors.error_list[5], #vim.api.nvim_buf_get_extmarks(ev.data.bufnr, ns, 0, -1, {}) }
			end,
		})
		finish()
		assert.are.equal("file.c", at_event[1].filename.value)
		assert.is_true(at_event[2] > 0)
	end)

	it("drains a deferred final tail when process exit precedes the queued consumer", function()
		start()
		local prefix, tail = string.rep("x", 65536), string.rep("y", 17000)
		callbacks.on_stdout(987654, { prefix })
		callbacks.on_stdout(987654, { tail })
		assert.are.same({ prefix .. tail }, finish())
	end)

	it("preserves ANSI and NUL fragments when EOF arrives after the consumer stopped", function()
		local config = require("compile-mode.config.internal")
		config.ansi_color = { kind = "render" }
		start()
		local prefix = string.rep("x", 65536)
		emit({ prefix .. "\27[" })
		emit({ "31mre\nd" })
		emit({ "\27[0m" })
		assert.are.same({ prefix .. "red" }, finish())
		local ns = vim.api.nvim_create_namespace("compile-mode-BaleiaColors")
		local marks = vim.api.nvim_buf_get_extmarks(finished.bufnr, ns, 0, -1, { details = true })
		local found = false
		for _, mark in ipairs(marks) do
			if mark[2] == 4 and mark[3] == #prefix and mark[4].end_col == #prefix + 3 then
				found = true
			end
		end
		assert.is_true(found)
	end)

	it("flushes a completed long line before max_lines terminates later output", function()
		require("compile-mode.config.internal").max_lines = 1
		start()
		local prefix = string.rep("x", 65536)
		emit({ prefix })
		emit({ "tail" })
		emit({ "", "discarded" })
		assert.are.equal(1, stopped)
		assert.are.same({ prefix .. "tail" }, finish())
		assert.are.equal(143, finished.code)
	end)

	it("discards a deferred suffix on interruption instead of flushing it into a later run", function()
		start()
		emit({ string.rep("x", 65536) })
		emit({ "must not leak" })
		local old = callbacks
		require("compile-mode").interrupt()
		drain()
		start()
		old.on_exit(987654, 0)
		emit({ "new output", "" })
		assert.are.same({ "new output", "" }, finish())
	end)

	it("flushes both interleaved long stream tails into their own rows and colors", function()
		colors()
		start()
		local out, err = string.rep("o", 65536), string.rep("e", 65536)
		emit({ "\27[31m" .. out })
		stderr({ "\27[34m" .. err })
		emit({ "OUT" })
		stderr({ "ERR" })
		assert.are.same({ out .. "OUT", err .. "ERR" }, finish())
		assert.are.equal(0xAB1234, foreground(0, #out + 2))
		assert.are.equal(0x1234AB, foreground(1, #err + 2))
	end)

	it("runs each OSC handler once across geometric snapshots and EOF", function()
		local config, calls = colors(), {}
		config.ansi_osc = {
			kind = "render",
			handlers = {
				[99] = function(ctx)
					calls[#calls + 1] = ctx.data
					return "[" .. ctx.data .. "]"
				end,
			},
		}
		start()
		local prefix, fragment = string.rep("x", 65536), string.rep("y", 50000)
		emit({ "\27]99;first\7" .. prefix })
		emit({ fragment })
		emit({ fragment })
		emit({ "\27]99;last\7END" })
		assert.are.same({ "[first]" .. prefix .. fragment .. fragment .. "[last]END" }, finish())
		assert.are.same({ "first", "last" }, calls)
	end)

	it("processes deferred controls discarded by CR, including a split SGR", function()
		local config, calls = colors(), 0
		config.ansi_osc =
			{ kind = "render", handlers = {
				[99] = function()
					calls = calls + 1
					return ""
				end,
			} }
		start()
		emit({ string.rep("x", 65536) .. "\27[3" })
		emit({ "1m\27]99;discarded\7" .. string.rep("y", 50000) })
		emit({ "\rEND" })
		assert.are.same({ "END" }, finish())
		assert.are.equal(1, calls)
		assert.are.equal(0xAB1234, foreground(0, 0))
	end)

	it("keeps deferred replay and discarded controls aligned when old rows are revisited", function()
		local config, calls = colors(), {}
		config.ansi_osc = {
			kind = "render",
			handlers = {
				[99] = function(ctx)
					calls[#calls + 1] = ctx.data
					return ""
				end,
			},
		}
		start()
		emit({ "\27[31m\27]99;old\7" .. string.rep("x", 65536) })
		emit({ string.rep("y", 1000) })
		stderr({ "stderr", "" })
		emit({ "\27]99;new\7\rEND", "\27[34m\27]99;row\7discard\rBLUE", "" })
		assert.are.same({ "END", "stderr", "BLUE", "" }, finish())
		assert.are.same({ "old", "new", "row" }, calls)
		assert.are.equal(0xAB1234, foreground(0, 0))
		assert.are.equal(0x1234AB, foreground(2, 0))
	end)

	it("retains hidden-pattern CR history without repeating OSC effects", function()
		local config, calls = colors(), 0
		config.hidden_output = { "secret\rpublic" }
		config.ansi_osc =
			{ kind = "render", handlers = {
				[99] = function()
					calls = calls + 1
					return ""
				end,
			} }
		start()
		local prefix = string.rep("x", 65536)
		emit({ "\27]99;first\7" .. prefix })
		emit({ "\27]99;second\7secret\r" })
		emit({ "publicEND" })
		assert.are.same({ prefix .. "END" }, finish())
		assert.are.equal(2, calls)
	end)
end)
