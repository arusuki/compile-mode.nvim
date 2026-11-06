local helpers = require("spec.test_helpers")
local assert = require("luassert")
local fast = require("compile-mode.ansi_fast")

local function visible_colors(bufnr, ns)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local result = {}
	for i, line in ipairs(lines) do
		result[i] = {}
		for col = 1, #line do
			result[i][col] = {}
		end
	end
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
		local details = assert(mark[4])
		local attributes = vim.api.nvim_get_hl(0, { name = details.hl_group, link = false })
		for row = mark[2], details.end_row do
			local first = row == mark[2] and mark[3] or 0
			local last = row == details.end_row and details.end_col or #(lines[row + 1] or "")
			for col = first, last - 1 do
				if result[row + 1] and result[row + 1][col + 1] then
					result[row + 1][col + 1] = attributes
				end
			end
		end
	end
	return result
end

describe("independent ANSI color rendering", function()
	before_each(function()
		helpers.setup_tests({ ansi_color = { kind = "render" } })
	end)

	it("matches Baleia's visible colors while omitting empty reset intervals", function()
		local options = { name = "FastAnsiParity", colors = { [2] = "#12ab34" } }
		local renderer = require("baleia").setup(options)
		local optimized = assert(fast.create(options, renderer))
		local expected = vim.api.nvim_create_buf(false, true)
		local actual = vim.api.nvim_create_buf(false, true)
		local lines = {
			"\27[32mgreen\27[0m",
			"\27[1;34mbold blue\27[0m",
			"\27[38;5;214morange\27[0m",
			"\27[38;2;23;45;67mtrue color\27[0m",
			"\27[4:3;31mcurly underline\27[0m",
			"\27[0;1;31mred after reset\27[0m",
			"\27[32m\27[0m",
			"",
		}
		renderer.buf_set_lines(expected, 0, -1, false, lines)
		assert.is_true(optimized(actual, 0, 1, lines))
		helpers.wait_for_schedule()
		local ns = vim.api.nvim_create_namespace(options.name)
		assert.are.same(
			vim.api.nvim_buf_get_lines(expected, 0, -1, false),
			vim.api.nvim_buf_get_lines(actual, 0, -1, false)
		)
		assert.are.same(visible_colors(expected, ns), visible_colors(actual, ns))
		assert.equals(6, #vim.api.nvim_buf_get_extmarks(actual, ns, 0, -1, {}))
	end)

	it("leaves multi-span and multi-line state to Baleia without changing the buffer", function()
		local options = { name = "FastAnsiFallback" }
		local renderer = require("baleia").setup(options)
		local optimized = assert(fast.create(options, renderer))
		local bufnr = vim.api.nvim_create_buf(false, true)
		for _, lines in ipairs({
			{ "\27[32mgreen", "continued\27[0m" },
			{ "\27[31mred\27[34mblue\27[0m" },
			{ "\27[31mred\27[0m", "plain" },
			{ "prefix\27[31mred\27[0m" },
		}) do
			assert.is_false(optimized(bufnr, 0, 1, lines))
			assert.are.same({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		end
	end)

	it("falls back for renderer options that change coordinates or logging", function()
		for _, options in ipairs({
			{ name = "FastAnsiRaw", strip_ansi_codes = false },
			{ name = "FastAnsiOffset", line_starts_at = 3 },
			{ name = "FastAnsiLog", log = true },
		}) do
			assert.is_nil(fast.create(options, { logger = {} }))
		end
		assert.is_nil(fast.create({ name = "OtherRenderer" }, {}))
	end)

	it("falls back when optional Baleia helper results are incompatible", function()
		local saved = package.loaded["baleia.highlight"]
		local options = { name = "FastAnsiUnsupported" }
		local renderer = require("baleia").setup(options)
		local bufnr = vim.api.nvim_create_buf(false, true)
		local ok, message = pcall(function()
			package.loaded["baleia.highlight"] = {}
			assert.is_nil(fast.create(options, renderer))
			package.loaded["baleia.highlight"] = {
				all = function()
					return { highlights = { false }, definitions = {} }
				end,
			}
			local optimized = assert(fast.create(options, renderer))
			assert.is_false(optimized(bufnr, 0, 1, { "\27[32mgreen\27[0m" }))
			assert.are.same({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		end)
		package.loaded["baleia.highlight"] = saved
		assert.is_true(ok, message)
	end)
end)
