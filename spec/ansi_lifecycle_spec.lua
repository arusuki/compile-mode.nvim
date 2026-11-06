local helpers = require("spec.test_helpers")
local assert = require("luassert")

describe("ANSI highlight lifecycle", function()
	local ansi, bufnr, colors
	local red = "\27[31mred\27[0m"
	local blue = "\27[34mblue\27[0m"

	local function marks(ns)
		return vim.api.nvim_buf_get_extmarks(bufnr, ns or colors, 0, -1, {})
	end

	before_each(function()
		helpers.setup_tests({ ansi_color = { kind = "render" }, ansi_osc = { kind = "render" } })
		ansi = require("compile-mode.ansi")
		bufnr = vim.api.nvim_create_buf(false, true)
		colors = vim.api.nvim_create_namespace("compile-mode-BaleiaColors")
	end)

	it("replaces colors without accumulating marks or deleting another consumer's marks", function()
		ansi.buf_set_lines(bufnr, 0, -1, { red })
		helpers.wait_for_schedule()
		local expected = #marks()
		assert.is_true(expected > 0)
		local foreign = vim.api.nvim_create_namespace("BaleiaColors")
		vim.api.nvim_buf_set_extmark(bufnr, foreign, 0, 0, { end_col = 1, hl_group = "Error" })
		for _ = 1, 10 do
			ansi.buf_set_lines(bufnr, 0, -1, { blue })
			helpers.wait_for_schedule()
			assert.equals(expected, #marks())
		end
		assert.equals(1, #marks(foreign))
	end)

	it("clears colors queued before an overwrite without a scheduling gap", function()
		ansi.buf_set_lines(bufnr, 0, -1, { red, red })
		ansi.buf_set_lines(bufnr, 0, -1, { blue })
		helpers.wait_for_schedule()
		local expected = #marks()
		assert.is_true(expected > 0)
		ansi.buf_set_lines(bufnr, 0, -1, { blue })
		helpers.wait_for_schedule()
		assert.equals(expected, #marks())
		ansi.buf_set_lines(bufnr, 0, -1, { "plain" })
		helpers.wait_for_schedule()
		assert.equals(0, #marks())
	end)

	it("only clears the replaced range and keeps colors on earlier output", function()
		ansi.buf_set_lines(bufnr, 0, -1, { red, blue })
		helpers.wait_for_schedule()
		local earlier = vim.tbl_filter(function(mark)
			-- Baleia's reset-at-EOL mark ends on the next row and is removed
			-- with that row. The visible color span must remain untouched.
			return mark[2] == 0 and mark[3] == 0
		end, marks())
		assert.is_true(#earlier > 0)
		ansi.buf_set_lines(bufnr, -2, -1, { "plain" })
		helpers.wait_for_schedule()
		assert.are.same(earlier, marks())
	end)

	it("resets queued colors and partial escapes before switching to plain output", function()
		ansi.buf_set_lines(bufnr, 0, -1, { red .. "\27[" })
		local config = require("compile-mode.config.internal")
		config.ansi_color = { kind = "filter" }
		ansi.reset(bufnr)
		ansi.buf_set_lines(bufnr, 0, -1, { "31mplain" })
		helpers.wait_for_schedule()
		assert.are.same({ "31mplain" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.equals(0, #marks())
	end)

	it("clears old OSC links while preserving new links after reset", function()
		local old_link = "\27]8;;https://old.example\27\\old\27]8;;\27\\"
		local new_link = "\27]8;;https://new.example\27\\new\27]8;;\27\\"
		ansi.buf_set_lines(bufnr, 0, -1, { old_link })
		ansi.reset(bufnr)
		ansi.buf_set_lines(bufnr, 0, -1, { new_link })
		helpers.wait_for_schedule()
		local links = vim.api.nvim_buf_get_extmarks(bufnr, ansi.ns_id, 0, -1, { details = true })
		assert.equals(1, #links)
		assert.equals("https://new.example", links[1][4].url)
		ansi.buf_set_lines(bufnr, 0, -1, { "plain" })
		assert.equals(0, #marks(ansi.ns_id))
	end)

	it("isolates configured Baleia names without changing the user's options", function()
		local config = require("compile-mode.config.internal")
		config.ansi_color.baleia_options = { name = "SharedColors", strip_ansi_codes = false }
		ansi.reset(bufnr)
		ansi.buf_set_lines(bufnr, 0, -1, { red })
		helpers.wait_for_schedule()
		local private = vim.api.nvim_create_namespace("compile-mode-SharedColors")
		assert.is_true(#marks(private) > 0)
		assert.are.same({ red }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.equals("SharedColors", config.ansi_color.baleia_options.name)
		local foreign = vim.api.nvim_create_namespace("SharedColors")
		vim.api.nvim_buf_set_extmark(bufnr, foreign, 0, 0, {})
		ansi.reset(bufnr)
		helpers.wait_for_schedule()
		assert.equals(0, #marks(private))
		assert.equals(1, #marks(foreign))
	end)

	it("retains every visible color span across output batches and recompilation", function()
		local count = 10000
		local green = 0x12AB34
		local config = require("compile-mode.config.internal")
		config.ansi_color.baleia_options = { colors = { [2] = "#12ab34" } }
		local command = require("scripts.support").command("scripts/producer.lua", "ansi", tostring(count))
		for run = 1, 2 do
			if run == 1 then
				helpers.compile({ args = command })
			else
				helpers.recompile({ args = command })
			end
			bufnr = helpers.get_compilation_bufnr()
			local lines = vim.api.nvim_buf_get_lines(bufnr, 4, 4 + count, false)
			local spans, attributes = {}, {}
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, colors, 0, -1, { details = true })) do
				local detail = mark[4]
				local hl = detail and detail.hl_group
				if detail and hl then
					attributes[hl] = attributes[hl] or vim.api.nvim_get_hl(0, { name = hl, link = false })
					if attributes[hl].fg == green then
						assert.is_nil(spans[mark[2]], "duplicate color span on output row " .. mark[2])
						spans[mark[2]] = { mark[3], detail.end_row, detail.end_col }
					end
				end
			end
			assert.equals(count, vim.tbl_count(spans))
			for i = 1, count do
				local row = i + 3 -- Four header rows precede the first output line.
				local text = "build " .. i
				assert.equals(text, lines[i])
				assert.are.same({ 0, row, #text }, spans[row], "missing green text on output row " .. row)
			end
		end
	end)
end)
