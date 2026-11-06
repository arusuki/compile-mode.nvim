local helpers = require("spec.test_helpers")
local errors = require("compile-mode.errors")
local cdir = require("compile-mode.dir")

describe("error list conversions", function()
	local root
	before_each(function()
		helpers.setup_tests()
		root = vim.fn.getcwd()
		cdir.compilation_directory = root
		cdir.dir_changes = {
			[5] = root .. "/build",
			[8] = root .. "/build/sub",
			[12] = root,
		}
	end)

	it("resolves quickfix files using output rows while retaining source rows", function()
		for _, item in ipairs({ { 6, "/build" }, { 9, "/build/sub" }, { 13, "" } }) do
			local error = assert(errors.parse("main.c:1:2: error: failure", item[1]))
			local qf = errors.toqflist({ error })
			assert.are.equal(root .. item[2] .. "/main.c", qf[1].filename)
			assert.are.equal(1, qf[1].lnum)
			assert.are.equal(2, qf[1].col)
		end
	end)

	it("separates identical filenames across directory transitions", function()
		local target = vim.fn.bufadd(root .. "/build/main.c")
		local items = {
			assert(errors.parse("main.c:1:2: error: first", 6)),
			assert(errors.parse("main.c:20:4: error: second", 7)),
			assert(errors.parse("main.c:1:2: error: nested", 9)),
			assert(errors.parse("main.c:1:2: error: root", 13)),
		}
		local diagnostics = errors.todiagnostic(target, items)
		assert.are.equal(2, #diagnostics)
		table.sort(diagnostics, function(a, b)
			return a.lnum < b.lnum
		end)
		assert.are.same({ 0, 19 }, { diagnostics[1].lnum, diagnostics[2].lnum })
		assert.are.same({ 1, 3 }, { diagnostics[1].col, diagnostics[2].col })
		assert.are.equal(target, diagnostics[1].bufnr)
		assert.are.equal(items[1].full_text, diagnostics[1].message)
		assert.are.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
	end)

	it("does not reuse filename resolution across directory changes between calls", function()
		local original = vim.fn.bufadd(root .. "/build/main.c")
		local replacement = vim.fn.bufadd(root .. "/other/main.c")
		local items = { assert(errors.parse("main.c:1:2: error: failure", 6)) }
		assert.are.equal(1, #errors.todiagnostic(original, items))
		cdir.dir_changes[5] = root .. "/other"
		assert.are.equal(0, #errors.todiagnostic(original, items))
		assert.are.equal(1, #errors.todiagnostic(replacement, items))
	end)

	it("preserves absolute paths and diagnostic ranges", function()
		local filename = root .. "/main.c"
		local target = vim.fn.bufadd(filename)
		local error = assert(errors.parse(filename .. ":3:4: error: failure", 6))
		error.end_row = { value = 7, range = { start = 1, end_ = 1 } }
		error.end_col = { value = 9, range = { start = 1, end_ = 1 } }
		local diagnostic = errors.todiagnostic(target, { error })[1]
		assert.are.same({ 2, 3, 6, 8 }, { diagnostic.lnum, diagnostic.col, diagnostic.end_lnum, diagnostic.end_col })
		assert.are.equal(filename, errors.toqflist({ error })[1].filename)
	end)

	it("keeps filename-only messages in quickfix without inventing diagnostic positions", function()
		require("compile-mode.config.internal").error_threshold = errors.level.INFO
		local error = assert(errors.parse('Found 1 error compiling "Main.java":', 6))
		assert.is_nil(error.row)
		local target = vim.fn.bufadd(root .. "/build/Main.java")
		assert.are.same({}, errors.todiagnostic(target, { error }))
		local qf = errors.toqflist({ error })
		assert.are.equal(root .. "/build/Main.java", qf[1].filename)
		assert.is_nil(qf[1].lnum)
	end)
end)
