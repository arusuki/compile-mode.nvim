local assert = require("luassert")
local helpers = require("spec.test_helpers")

describe("compilation mouse navigation", function()
	local source, compilation, source_win, compilation_win, mouse, filename

	local function click(win, row, col)
		vim.cmd("redraw")
		local pos = vim.fn.screenpos(win, row, col)
		vim.api.nvim_input_mouse("left", "press", "", 0, pos.row - 1, pos.col - 1)
		helpers.wait_ms(20)
		vim.api.nvim_input_mouse("left", "release", "", 0, pos.row - 1, pos.col - 1)
		helpers.wait_ms(20)
	end

	before_each(function()
		vim.cmd("only!")
		helpers.setup_tests()
		mouse = vim.o.mouse
		vim.o.mouse = "a"
		source = vim.api.nvim_get_current_buf()
		source_win = vim.api.nvim_get_current_win()
		vim.bo[source].swapfile = false
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "first line", "second line", "third line" })
		filename = vim.fn.tempname() .. ".lua"
		vim.fn.writefile(vim.api.nvim_buf_get_lines(source, 0, -1, false), filename)
		vim.api.nvim_buf_set_name(source, filename)
		vim.cmd("new")
		compilation = vim.api.nvim_get_current_buf()
		compilation_win = vim.api.nvim_get_current_win()
		vim.bo[compilation].swapfile = false
		vim.api.nvim_buf_set_lines(compilation, 0, -1, false, { "Compilation output" })
		vim.bo[compilation].filetype = "compilation"
	end)

	after_each(function()
		vim.o.mouse = mouse
		vim.cmd("only!")
		vim.fn.delete(filename)
	end)

	it("allows clicking from compilation into a normal buffer", function()
		vim.api.nvim_set_current_win(source_win)
		click(compilation_win, 1, 1)
		assert.equals(compilation, vim.api.nvim_get_current_buf())
		vim.v.errmsg = ""
		click(source_win, 2, 3)
		assert.equals("", vim.v.errmsg)
		assert.equals(source, vim.api.nvim_get_current_buf())
		assert.are.same({ 2, 2 }, vim.api.nvim_win_get_cursor(source_win))
	end)

	it("still jumps to the source location when clicking a compilation error", function()
		vim.api.nvim_buf_set_lines(compilation, 0, -1, false, { filename .. ":2:3: error: example" })
		helpers.wait_ms(20)
		vim.v.errmsg = ""
		click(compilation_win, 1, 1)
		assert.equals("", vim.v.errmsg)
		assert.equals(source, vim.api.nvim_get_current_buf())
		assert.are.same({ 2, 2 }, vim.api.nvim_win_get_cursor(0))
	end)
end)
