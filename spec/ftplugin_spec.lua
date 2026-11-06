local helpers = require("spec.test_helpers")
local assert = require("luassert")

describe("compilation window highlights", function()
	local buf, source, win

	local function matches(window)
		return vim.tbl_filter(function(match)
			return match.group:match("^CompileMode") ~= nil
		end, vim.fn.getmatches(window or win))
	end

	before_each(function()
		vim.cmd("only!")
		helpers.setup_tests()
		source = vim.api.nvim_create_buf(false, true)
		buf = vim.api.nvim_create_buf(false, true)
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].filetype = "compilation"
	end)

	it("removes only its matches on buffer leave and restores them on return", function()
		local count = #matches()
		assert.is_true(count > 0)
		local foreign = vim.fn.matchadd("Error", "foreign highlight")
		vim.api.nvim_set_current_buf(source)
		assert.equals(0, #matches())
		assert.equals(foreign, vim.fn.getmatches(win)[1].id)
		vim.api.nvim_set_current_buf(buf)
		assert.equals(count, #matches())
		assert.equals(count + 1, #vim.fn.getmatches(win))
		vim.fn.matchdelete(foreign, win)
	end)

	it("deduplicates patterns and buffer autocmds across filetype re-entry", function()
		local count = #matches()
		local events = #vim.api.nvim_get_autocmds({ group = "compile-mode.nvim", buffer = buf })
		assert.is_true(events > 0)
		for _ = 1, 10 do
			vim.bo[buf].filetype = "compilation"
		end
		assert.equals(count, #matches())
		assert.equals(events, #vim.api.nvim_get_autocmds({ group = "compile-mode.nvim", buffer = buf }))
	end)

	it("tracks multiple windows independently", function()
		local count = #matches()
		vim.cmd("split")
		local second = vim.api.nvim_get_current_win()
		assert.equals(count, #matches(second))
		assert.equals(count, #matches(win))
		vim.api.nvim_win_set_buf(win, source)
		assert.equals(0, #matches(win))
		assert.equals(count, #matches(second))
		vim.api.nvim_win_set_buf(win, buf)
		assert.equals(count, #matches(win))
		vim.api.nvim_set_current_buf(source)
		assert.equals(0, #matches(second))
		assert.equals(count, #matches(win))
		vim.api.nvim_set_current_buf(buf)
		assert.equals(count, #matches(second))
		vim.api.nvim_win_close(second, true)
		assert.equals(count, #matches(win))
	end)

	it("clears matches when the buffer changes filetype or is deleted", function()
		local foreign = vim.fn.matchadd("Error", "foreign highlight")
		local count = #matches()
		vim.bo[buf].filetype = "lua"
		assert.equals(0, #matches())
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "compile-mode.nvim", buffer = buf }))
		vim.bo[buf].filetype = "compilation"
		assert.equals(count, #matches())
		vim.api.nvim_buf_delete(buf, { force = true })
		assert.equals(0, #matches())
		assert.equals(foreign, vim.fn.getmatches(win)[1].id)
		vim.fn.matchdelete(foreign, win)
	end)
end)
