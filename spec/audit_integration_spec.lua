local assert = require("luassert")
local helpers = require("spec.test_helpers")
local support = require("scripts.support")

-- Exercise the boundaries between task ownership, stream tails, ANSI state and
-- parser metadata with actual subprocesses, independently of callback mocks.
describe("compilation audit integration", function()
	local producer

	before_each(function()
		helpers.setup_tests()
		support.setup({ ansi_color = { kind = "render" }, ansi_osc = { kind = "render" } })
	end)

	after_each(function()
		if producer then
			vim.fn.delete(producer)
			producer = nil
		end
	end)

	it("keeps interleaved stream text, colors, OSC effects and diagnostic paths consistent", function()
		producer = vim.fn.tempname() .. ".lua"
		vim.fn.writefile({
			[[io.stdout:write('\27[31m\27]9;one notification\7out')]],
			[[io.stdout:flush()]],
			[[vim.uv.sleep(35)]],
			[[io.stderr:write('err.c:2:3: error: stderr failure\n')]],
			[[io.stderr:flush()]],
			[[vim.uv.sleep(35)]],
			[[io.stdout:write('put\nsecond\27[0m\n')]],
			[[io.stdout:flush()]],
		}, producer)
		local notifications = 0
		local config = require("compile-mode.config.internal")
		config.ansi_osc.handlers = {
			[9] = function()
				notifications = notifications + 1
				return ""
			end,
		}
		config.ansi_color.baleia_options = { colors = { [1] = "#ab1234" } }
		local event = support.compile(support.command(producer))
		local lines = vim.api.nvim_buf_get_lines(event.bufnr, 4, -3, false)
		assert.are.equal(1, notifications)
		local expected = { output = true, second = true, ["err.c:2:3: error: stderr failure"] = true }
		for _, line in ipairs(lines) do
			if line ~= "" then
				assert.is_true(expected[line], "unexpected or duplicated output: " .. line)
				expected[line] = nil
			end
		end
		assert.is_nil(next(expected), "missing stream output")
		local files = {}
		for _, err in pairs(require("compile-mode.errors").error_list) do
			files[#files + 1] = err.filename.value
		end
		assert.are.same({ "err.c" }, files)

		local covered = {}
		local ns = vim.api.nvim_create_namespace("compile-mode-BaleiaColors")
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(event.bufnr, ns, 0, -1, { details = true })) do
			local detail = mark[4]
			if detail and detail.hl_group then
				local attributes = vim.api.nvim_get_hl(0, { name = detail.hl_group, link = false })
				if attributes.fg == 0xAB1234 then
					local line = lines[mark[2] - 3]
					assert.is_true(line == "output" or line == "second", "stdout color leaked into stderr")
					if mark[3] == 0 and detail.end_row == mark[2] and detail.end_col == #line then
						covered[line] = true
					end
				end
			end
		end
		assert.are.same({ output = true, second = true }, covered)
	end)

	it("publishes only the latest output when real jobs are requested in the same turn", function()
		local events = {}
		local event_id = vim.api.nvim_create_autocmd("User", {
			pattern = "CompilationFinished",
			callback = function(event)
				events[#events + 1] = event.data
			end,
		})
		local cm = require("compile-mode")
		local first = support.command("scripts/producer.lua", "plain", "1")
		local second = support.command("scripts/producer.lua", "plain", "2")
		cm.compile({ args = first, smods = { silent = true } })
		cm.compile({ args = second, smods = { silent = true } })
		local finished = vim.wait(5000, function()
			return #events > 0
		end, 1)
		vim.api.nvim_del_autocmd(event_id)
		assert.is_true(finished)
		support.drain()
		assert.are.equal(1, #events)
		assert.are.equal(second, events[1].command)
		local lines = vim.api.nvim_buf_get_lines(events[1].bufnr, 0, -1, false)
		local headers, output = 0, {}
		for _, line in ipairs(lines) do
			if line:match("^Compilation started") then
				headers = headers + 1
			elseif line:match("^build step") then
				output[#output + 1] = line
			end
		end
		assert.are.equal(1, headers)
		assert.are.same({ "build step 1 complete", "build step 2 complete" }, output)
	end)
end)
