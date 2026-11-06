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

	it("keeps error and command highlights bounded across unchanged rescans", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"main.c:12:3: error: failure",
			"make[2]: compiling",
		})
		parser.parse(bufnr, 0, -1)
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
		assert.is_true(#marks > 0)
		for _ = 1, 20 do
			parser.parse(bufnr, 0, -1)
		end
		assert.are.equal(#marks, #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
	end)

	it("replaces stale error records and marks without touching other rows or namespaces", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"main.c:12:3: error: failure",
			"other.c:21:4: warning: retained",
		})
		parser.parse(bufnr, 0, -1)
		local other_error = errors.error_list[2]
		local outside = vim.api.nvim_buf_get_extmarks(bufnr, ns, { 1, 0 }, -1, {})
		local foreign_ns = vim.api.nvim_create_namespace("parser-spec-foreign")
		local foreign_mark = vim.api.nvim_buf_set_extmark(bufnr, foreign_ns, 1, 0, {})
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "build succeeded" })
		parser.parse(bufnr, 0, 1)
		assert.is_nil(errors.error_list[1])
		assert.are.equal(other_error, errors.error_list[2])
		assert.are.same(outside, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
		assert.are.same({ 1, 0 }, vim.api.nvim_buf_get_extmark_by_id(bufnr, foreign_ns, foreign_mark, {}))
	end)

	it("removes command prefix marks when its line is replaced", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "make[2]: compiling", "plain output" })
		parser.parse(bufnr, 0, -1)
		assert.is_true(#vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) > 0)
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "done" })
		parser.parse(bufnr, 0, 1)
		assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
	end)

	it("discards deleted tail metadata after a shortened log is scanned", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"build started",
			"make: Entering directory 'spec'",
			"main.c:12:3: error: failure",
		})
		parser.parse(bufnr, 0, -1)
		assert.is_not_nil(cdir.dir_changes[2])
		assert.is_not_nil(errors.error_list[3])
		vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, {})
		parser.parse(bufnr, 0, 1)
		assert.are.same({}, errors.error_list)
		assert.are.same({}, cdir.dir_changes)
		assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
	end)

	it("removes an obsolete directory transition when its line is rescanned", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "make: Entering directory 'spec'", "output" })
		parser.parse(bufnr, 0, -1)
		assert.are.equal(cdir.compilation_directory .. "/spec", cdir.find_directory_for_line(2))
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "building" })
		parser.parse(bufnr, 0, 1)
		assert.are.equal(cdir.compilation_directory, cdir.find_directory_for_line(2))
	end)

	it("renders independent pending scans and ignores superseded highlights", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"make[2]: building",
			"main.c:12:3: error: failure",
			"other.c:21:4: warning: retained",
		})
		local obsolete = parser.scan(bufnr, 0, 2)
		local independent = parser.scan(bufnr, 2, 3)
		vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, { "done", "success" })
		local replacement = parser.scan(bufnr, 0, 2)
		parser.render(bufnr, replacement)
		parser.render(bufnr, obsolete)
		parser.render(bufnr, independent)
		assert.is_nil(errors.error_list[2])
		assert.is_true(errors.error_list[3].highlighted)
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
		assert.is_true(#marks > 0)
		for _, mark in ipairs(marks) do
			assert.are.equal(2, mark[2])
		end
	end)

	it("does not apply a pending render after session reset", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "make[2]: building", "main.c:12:3: error: failure" })
		local obsolete = parser.scan(bufnr, 0, -1)
		state.reset()
		parser.render(bufnr, obsolete)
		assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
	end)

	it("uses absolute metadata coordinates for a negative buffer range", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain", "main.c:12:3: error: failure" })
		parser.parse(bufnr, -2, -1)
		assert.are.equal(2, errors.error_list[2].linenum)
		assert.is_true(errors.error_list[2].highlighted)
	end)
end)
