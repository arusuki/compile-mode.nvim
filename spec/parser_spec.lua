local assert = require("luassert")
local helpers = require("spec.test_helpers")
local parser = require("compile-mode.parser")
local errors = require("compile-mode.errors")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")

-- Exercise the scan/render boundary with a log buffer, without launching a job.
describe("compilation buffer parsing", function()
	local bufnr
	local ns = vim.api.nvim_create_namespace("compile-mode.nvim")

	before_each(function()
		helpers.setup_tests()
		state.reset()
		cdir.compilation_directory = vim.fn.getcwd()
		bufnr = vim.api.nvim_create_buf(false, true)
	end)

	it("tracks absolute output line numbers and directory context before rendering", function()
		local message = helpers.sun_ada_error({ filename = "example.c", row = 100, col = 3 })
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"vim: filetype=compilation",
			"Compilation started",
			"",
			"make",
			"make: Entering directory 'spec'",
			message,
			"make: building target",
		})

		local highlights = parser.scan(bufnr, 4, 7)
		assert.are.equal(6, errors.error_list[6].linenum)
		assert.are.equal(100, errors.error_list[6].row.value)
		assert.are.equal(cdir.compilation_directory .. "/spec", cdir.find_directory_for_line(6))
		assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))

		parser.render(bufnr, highlights)
		assert.is_true(errors.error_list[6].highlighted)
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
		assert.is_true(#marks > 0)
		assert.is_true(vim.iter(marks):any(function(mark)
			return mark[2] == 5 -- one-based error line 6 becomes zero-based extmark row 5
		end))
	end)

	it("keeps the existing full-buffer parsing hook working", function()
		local message = helpers.sun_ada_error({ filename = "example.c", row = 2, col = 1 })
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "build output", message })
		require("compile-mode")._parse_errors(bufnr, 0, -1)
		assert.are.equal(message, errors.error_list[2].full_text)
		assert.is_true(errors.error_list[2].highlighted)
	end)
end)
