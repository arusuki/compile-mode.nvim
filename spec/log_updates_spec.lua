local helpers = require("spec.test_helpers")
local parser = require("compile-mode.parser")
local errors = require("compile-mode.errors")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")
local s = require("scripts.support")
local assert = require("luassert")

local function log_buffer(lines, main)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(buf)
	vim.b[buf].compilation_main_buffer = main or nil
	vim.bo[buf].filetype = "compilation"
	if main then
		parser.parse(buf, 0, -1)
	end
	return buf
end

describe("incremental editable compilation logs", function()
	local scan, calls, busy
	before_each(function()
		vim.cmd("only!")
		helpers.setup_tests({ auto_jump_to_first_error = false })
		state.reset()
		vim.g.compile_job_id = nil
		cdir.compilation_directory = "/project"
		scan = parser.scan
		calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		parser.scan = function(buf, first, last)
			calls[#calls + 1] = { buf, first, last }
			return scan(buf, first, last)
		end
		local runner = require("compile-mode.runner")
		busy = runner.is_busy
		---@diagnostic disable-next-line: duplicate-set-field
		runner.is_busy = function()
			return false
		end
	end)

	after_each(function()
		parser.scan = scan
		require("compile-mode.runner").is_busy = busy
	end)

	it("coalesces tail edits and never reparses the unchanged prefix", function()
		local lines = {}
		for i = 1, 10000 do
			lines[i] = "plain output"
		end
		lines[1] = "keep.c:2:1: error: retained"
		local buf = log_buffer(lines)
		local retained = errors.error_list[1]
		calls = {}
		vim.api.nvim_buf_set_lines(buf, 9999, -1, false, { "tail.c:2:1: error: temporary" })
		vim.api.nvim_buf_set_lines(buf, 9999, -1, false, { "tail.c:3:1: warning: final" })
		s.drain()
		assert.are.same({ { buf, 9999, -1 } }, calls)
		assert.are.equal(retained, errors.error_list[1])
		assert.are.equal(3, errors.error_list[10000].row.value)
		assert.are.same({ error = 1, warning = 1, info = 0 }, errors.counts())
	end)

	it("rebuilds shifted suffix metadata after insertion and deletion", function()
		local buf = log_buffer({ "first.c:1:1: error: first", "plain", "last.c:3:1: error: last" })
		state.error_cursor = 3
		vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "new.c:2:1: error: inserted", "plain" })
		s.drain()
		assert.are.same({ 1, 2, 5 }, errors.ordered_lines())
		assert.are.equal(5, errors.error_list[5].linenum)
		assert.are.equal(5, state.error_cursor)
		vim.api.nvim_buf_set_lines(buf, 1, 4, false, {})
		s.drain()
		assert.are.same({ 1, 2 }, errors.ordered_lines())
		assert.are.equal("last.c", errors.error_list[2].filename.value)
		assert.are.equal(2, state.error_cursor)
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, {})
		s.drain()
		assert.are.same({ 1 }, errors.ordered_lines())
		assert.are.equal(0, state.error_cursor)
	end)

	it("recomputes downstream relative directories after editing a transition", function()
		local buf = log_buffer({ "cd one", "first.c:1:1: error: first", "cd two", "last.c:3:1: error: last" })
		assert.are.equal("/project/one/two/last.c", cdir.resolve_filename("last.c", 4))
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "cd changed" })
		s.drain()
		assert.are.equal("/project/changed/two/last.c", cdir.resolve_filename("last.c", 4))
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "plain" })
		s.drain()
		assert.are.equal("/project/two/last.c", cdir.resolve_filename("last.c", 4))
	end)

	it("rebuilds errors and marks after undo", function()
		local buf = log_buffer({ "first.c:1:1: error: first", "last.c:3:1: error: last" })
		-- Start a fresh undo sequence, so undo restores the prepared log.
		vim.cmd("let &undolevels = &undolevels")
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, { "plain" })
		s.drain()
		assert.are.same({ 1 }, errors.ordered_lines())
		vim.cmd("undo")
		s.drain()
		assert.are.same({ 1, 2 }, errors.ordered_lines())
		assert.is_true(errors.error_list[2].highlighted)
	end)

	it("rebuilds metadata after an on-disk reload", function()
		local filename = vim.fn.tempname() .. ".log"
		vim.fn.writefile({ "first.c:1:1: error: first", "last.c:3:1: error: last" }, filename)
		local buf = log_buffer({ "first.c:1:1: error: first", "last.c:3:1: error: last" })
		vim.api.nvim_buf_set_name(buf, filename)
		vim.bo[buf].buftype = ""
		vim.fn.writefile({ "new.c:2:1: warning: reloaded" }, filename)
		vim.cmd("edit!")
		s.drain()
		assert.are.same({ 1 }, errors.ordered_lines())
		assert.are.equal("new.c", errors.error_list[1].filename.value)
		assert.are.same({ error = 0, warning = 1, info = 0 }, errors.counts())
		vim.fn.delete(filename)
	end)

	it("defers background logs and rebuilds the selected buffer on return", function()
		local first = log_buffer({ "one.c:1:1: error: first", "retained.c:2:1: error: first" })
		local second = log_buffer({ "two.c:1:1: error: second" })
		assert.are.same({ 1 }, errors.ordered_lines())
		assert.are.equal("two.c", errors.error_list[1].filename.value)
		calls = {}
		vim.api.nvim_buf_set_lines(first, 0, 1, false, { "changed.c:1:1: error: changed" })
		s.drain()
		assert.are.same({}, calls)
		assert.are.equal(second, vim.g.compilation_buffer)
		vim.api.nvim_set_current_buf(first)
		assert.are.equal("changed.c", errors.error_list[1].filename.value)
		assert.are.same({ 1, 2 }, errors.ordered_lines())
		vim.api.nvim_set_current_buf(second)
		assert.are.equal("two.c", errors.error_list[1].filename.value)
		assert.are.same({ 1 }, errors.ordered_lines())
	end)

	it("does not steal a preparing/running command's metadata and restores main ownership", function()
		local main = log_buffer({ "main.c:1:1: error: main" }, true)
		local main_error = errors.error_list[1]
		---@diagnostic disable-next-line: duplicate-set-field
		require("compile-mode.runner").is_busy = function()
			return true
		end
		local log = log_buffer({ "other.c:1:1: error: log" })
		vim.api.nvim_buf_set_lines(log, 0, 1, false, { "edited.c:1:1: error: edited" })
		s.drain()
		assert.are.equal(main, vim.g.compilation_buffer)
		assert.are.equal(main_error, errors.error_list[1])
		---@diagnostic disable-next-line: duplicate-set-field
		require("compile-mode.runner").is_busy = function()
			return false
		end
		vim.api.nvim_set_current_buf(main)
		vim.api.nvim_set_current_buf(log)
		assert.are.equal("edited.c", errors.error_list[1].filename.value)
		vim.api.nvim_set_current_buf(main)
		assert.are.equal(main, vim.g.compilation_buffer)
		assert.are.equal("main.c", errors.error_list[1].filename.value)
	end)

	it("discards a deferred render when attached log text has changed", function()
		local buf = log_buffer({ "main.c:1:1: error: failure" })
		local obsolete = parser.scan(buf, 0, -1)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain" })
		parser.render(buf, obsolete)
		s.drain()
		assert.are.same({}, errors.error_list)
		local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
		assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
	end)

	it("keeps one consumer after filetype re-entry and drops pending work on detach/delete", function()
		local buf = log_buffer({ "plain" })
		for _ = 1, 5 do
			vim.bo[buf].filetype = "compilation"
		end
		calls = {}
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "main.c:1:1: error: failure" })
		s.drain()
		assert.are.equal(1, #calls)
		calls = {}
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain" })
		vim.bo[buf].filetype = "text"
		s.drain()
		assert.are.same({}, calls)
		vim.bo[buf].filetype = "compilation"
		calls = {}
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "main.c:1:1: error: failure" })
		vim.api.nvim_buf_delete(buf, { force = true })
		s.drain()
		assert.are.same({}, calls)
	end)
end)
