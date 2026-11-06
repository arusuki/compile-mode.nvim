local helpers = require("spec.test_helpers")
local errors = require("compile-mode.errors")
local state = require("compile-mode.state")
local cdir = require("compile-mode.dir")
local navigation = require("compile-mode.navigation")
local utils = require("compile-mode.utils")

local silent = { smods = { silent = true } }

local function message(filename, line)
	return assert(errors.parse(filename .. ":2:1: error: failure", line))
end

describe("navigation after metadata edits", function()
	before_each(function()
		helpers.setup_tests()
		state.reset()
		cdir.compilation_directory = vim.fn.getcwd()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "", "", "" })
	end)

	it("continues in both directions after the selected error disappears", function()
		for _, line in ipairs({ 1, 3, 5 }) do
			errors.set_error(line, message("main.c", line))
		end
		state.error_cursor = 3
		errors.set_error(3, nil)
		navigation.move_to_next_error(silent)
		assert.are.equal(5, state.error_cursor)
		state.error_cursor = 3
		navigation.move_to_prev_error(silent)
		assert.are.equal(1, state.error_cursor)
	end)

	it("applies thresholds and counts from an absent cursor's insertion point", function()
		errors.set_error(1, message("main.c", 1))
		local ignored = message("main.c", 3)
		ignored.level = errors.level.INFO
		errors.set_error(3, ignored)
		errors.set_error(4, message("main.c", 4))
		errors.set_error(5, message("main.c", 5))
		state.error_cursor = 2
		navigation.move_to_next_error({ count = 2, smods = { silent = true } })
		assert.are.equal(5, state.error_cursor)
	end)

	it("distinguishes same-named files in different output directories", function()
		cdir.compilation_directory = "/project/one"
		cdir.set_directory(2, "/project/two")
		errors.set_error(1, message("main.c", 1))
		errors.set_error(3, message("main.c", 3))
		state.error_cursor = 1
		navigation.move_to_next_file(silent)
		assert.are.equal(3, state.error_cursor)
		navigation.move_to_prev_file(silent)
		assert.are.equal(1, state.error_cursor)
	end)

	it("treats normalized relative and absolute aliases as the same file", function()
		cdir.compilation_directory = "/project"
		errors.set_error(1, message("./src/../main.c", 1))
		errors.set_error(2, message("/project/main.c", 2))
		errors.set_error(3, message("other.c", 3))
		state.error_cursor = 1
		navigation.move_to_next_file(silent)
		assert.are.equal(3, state.error_cursor)
	end)

	it("keeps warning severity in generic and cached diagnostics", function()
		local error = assert(errors.parse("main.c:2:1: warning: failure", 1))
		local buf = vim.fn.bufadd(cdir.resolve_filename("main.c", 1))
		errors.set_error(1, error)
		assert.are.equal(vim.diagnostic.severity.WARN, errors.todiagnostic(buf, { error })[1].severity)
		assert.are.equal(vim.diagnostic.severity.WARN, errors.diagnostics_for_buffer(buf)[1].severity)
	end)
end)

describe("source locus bounds", function()
	local source, compilation, filename
	local ns = vim.api.nvim_create_namespace("compile-mode.nvim/highlight")
	before_each(function()
		helpers.setup_tests({ error_locus_highlight = true })
		state.reset()
		filename = vim.fn.tempname() .. ".c"
		vim.fn.writefile({ "abcdef", "tail" }, filename)
		source = vim.fn.bufadd(filename)
		vim.fn.bufload(source)
		compilation = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(compilation, 0, -1, false, { "error" })
		vim.g.compilation_buffer = compilation
		vim.api.nvim_set_current_buf(source)
	end)

	after_each(function()
		vim.fn.delete(filename)
	end)

	local function jump(row, col, end_row, end_col)
		local error = message(filename, 1)
		error.row.value, error.col.value = row, col
		error.end_row = end_row and { value = end_row }
		error.end_col = end_col and { value = end_col }
		utils.jump_to_error(error, vim.fn.getcwd(), {})
	end

	it("uses matching zero-based cursor and highlight columns", function()
		jump(1, 2, 1, 3)
		assert.are.same({ 1, 1 }, vim.api.nvim_win_get_cursor(0))
		local marks = vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })
		assert.are.equal(1, #marks)
		assert.are.same({ 0, 1, 0, 3 }, { marks[1][2], marks[1][3], marks[1][4].end_row, marks[1][4].end_col })
	end)

	it("clamps stale source locations after the file shrinks", function()
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "x" })
		jump(999, 999, 1000, 1000)
		assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
		local marks = vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })
		assert.are.equal(1, #marks)
		assert.are.same({ 0, 0, 0, 1 }, { marks[1][2], marks[1][3], marks[1][4].end_row, marks[1][4].end_col })
	end)

	it("handles zero positions, empty lines and reversed ranges", function()
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "", "abc" })
		jump(0, 0, 0, 0)
		assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
		jump(2, 2, 1, 1)
		assert.are.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
	end)

	it("clamps byte columns to UTF-8 character boundaries", function()
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "a界" })
		jump(1, 999)
		assert.are.same({ 1, 1 }, vim.api.nvim_win_get_cursor(0))
	end)
end)
