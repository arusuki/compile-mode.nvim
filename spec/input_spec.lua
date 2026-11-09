local assert = require("luassert")
local input = require("compile-mode.input")
local buffer = require("compile-mode.buffer")
local helpers = require("spec.test_helpers")
local support = require("scripts.support")

local function open(buf)
	vim.api.nvim_set_current_buf(buf)
	input.enter(buf)
	vim.api.nvim_feedkeys("", "nx", false)
end

local function draft(buf, lines)
	vim.api.nvim_buf_set_lines(buf, input.count(buf), -1, false, lines)
end

describe("protected compilation input", function()
	local buf, sent, fail
	before_each(function()
		helpers.setup_tests()
		support.setup()
		buf = support.buffer({ "header", "prompt: " })
		sent, fail = {}, false
		input.attach(buf, function(text)
			if fail then
				return false, "closed"
			end
			sent[#sent + 1] = text
			return true
		end)
		open(buf)
	end)

	after_each(function()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("sends multiline and empty answers and never resends history", function()
		draft(buf, { "one", "two" })
		input.submit(buf)
		input.submit(buf)
		assert.are.same({ "one\ntwo\n", "\n" }, sent)
		assert.are.same(
			{ "header", "prompt: ", "> one", "> two", "> ", "" },
			vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		)
	end)

	it("preserves a failed submission and rejects submission after exit", function()
		draft(buf, { "unsent" })
		fail = true
		assert.has_error(function()
			input.submit(buf)
		end, "closed")
		assert.is_true(input.has_draft(buf))
		input.finish(buf)
		assert.has_error(function()
			input.submit(buf)
		end, "No running compilation")
		assert.are.same({ "unsent" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
	end)

	it("rejects a cross-boundary edit as a whole", function()
		draft(buf, { "keep" })
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, { "bad" })
		support.drain()
		assert.are.same({ "header", "prompt: ", "keep" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		input.submit(buf)
		assert.are.same({ "keep\n" }, sent)
	end)

	it("preserves the draft and undo journal while output arrives", function()
		draft(buf, { "one" })
		draft(buf, { "two", "three" })
		vim.api.nvim_win_set_cursor(0, { 4, 2 })
		buffer.set_lines(buf, -1, -1, { "output" }, false)
		assert.are.same({ 5, 2 }, vim.api.nvim_win_get_cursor(0))
		input.undo(buf, false)
		assert.are.same({ "header", "prompt: ", "output", "one" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		input.undo(buf, true)
		assert.are.same({ "two", "three" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
		input.submit(buf)
		input.undo(buf, false)
		assert.is_false(input.has_draft(buf))
	end)

	it("keeps an unsent draft below the completion footer", function()
		draft(buf, { "keep" })
		input.finish(buf)
		buffer.set_lines(buf, -1, -1, { "finished" }, false)
		assert.are.same({ "header", "prompt: ", "finished", "keep" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)
	it("restores an empty editable line when the whole draft is deleted", function()
		draft(buf, { "delete" })
		vim.api.nvim_buf_set_lines(buf, input.count(buf), -1, false, {})
		support.drain()
		assert.are.same({ "" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
		input.submit(buf)
		assert.are.same({ "\n" }, sent)
	end)

	it("excludes input records and drafts from diagnostic parsing", function()
		draft(buf, { "README.md:1: error: submitted" })
		input.submit(buf)
		draft(buf, { "README.md:2: error: draft" })
		require("compile-mode.parser").parse(buf, 0, -1)
		assert.are.equal(0, vim.tbl_count(require("compile-mode.errors").error_list))
		assert.are.equal(2, input.output_count(buf))
	end)

	it("renders ANSI output while preserving editable input", function()
		draft(buf, { "keep" })
		local config = require("compile-mode.config.internal")
		config.ansi_color = { kind = "render" }
		local ansi = require("compile-mode.ansi")
		ansi.reset(buf)
		ansi.buf_set_lines(buf, -1, -1, { "\027[31mred\027[0m" })
		support.drain()
		assert.are.same({ "header", "prompt: ", "red", "keep" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		assert.is_true(vim.bo[buf].modifiable)
	end)

	it("trims output without trimming the draft or counting submitted input", function()
		-- The first four lines are compilation headers, as in a real session.
		buffer.set_lines(buf, 0, 0, { "header3", "header4" }, false)
		draft(buf, { "record" })
		input.submit(buf)
		draft(buf, { "keep" })
		require("compile-mode.config.internal").max_lines = 2
		buffer.set_lines(buf, -1, -1, { "one", "two", "three" })
		assert.are.same({ "keep" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
		assert.are.equal(6, input.output_count(buf))
	end)
	it("undoes an insertion as one draft edit with normal Vim keys", function()
		vim.cmd("filetype plugin on")
		vim.b[buf].compilation_main_buffer = true
		vim.bo[buf].filetype = "compilation"
		vim.api.nvim_feedkeys("ihello" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
		assert.are.same({ "hello" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
		vim.api.nvim_feedkeys("u", "xt", false)
		assert.are.same({ "" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>", true, false, true), "xt", false)
		assert.are.same({ "hello" }, vim.api.nvim_buf_get_lines(buf, input.count(buf), -1, false))
	end)
	it("defers text listeners and undo changes until input is used", function()
		local other = support.buffer({ "output" })
		local native_undo = vim.bo[other].undolevels
		local attach, calls = vim.api.nvim_buf_attach, 0
		---@diagnostic disable-next-line: duplicate-set-field
		vim.api.nvim_buf_attach = function(b, send, opts)
			if b == other then
				calls = calls + 1
			end
			return attach(b, send, opts)
		end
		local ok, err = pcall(function()
			input.attach(other, function()
				return true
			end)
			buffer.set_lines(other, -1, -1, { "more output" }, false)
			assert.are.equal(0, calls)
			assert.are.equal(native_undo, vim.bo[other].undolevels)
			assert.is_false(vim.bo[other].modifiable)
			open(other)
			assert.are.equal(1, calls)
			assert.are.equal(-1, vim.bo[other].undolevels)
			assert.is_true(vim.bo[other].modifiable)
		end)
		vim.api.nvim_buf_attach = attach
		vim.api.nvim_buf_delete(other, { force = true })
		assert.is_true(ok, err)
	end)
end)
