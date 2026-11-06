local helpers = require("spec.test_helpers")
local s = require("scripts.support")
local ansi = require("compile-mode.ansi")
local output = require("compile-mode.output")

local function snapshot(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local pixels = {}
	for i, line in ipairs(lines) do
		pixels[i] = {}
		for j = 1, #line do
			pixels[i][j] = {}
		end
	end
	for _, ns in ipairs({ vim.api.nvim_create_namespace("compile-mode-BaleiaColors"), ansi.ns_id }) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
			local details = assert(mark[4])
			assert.equals(mark[2], details.end_row, "stream marks must stay within their own output row")
			for col = mark[3] + 1, details.end_col do
				if pixels[mark[2] + 1] and pixels[mark[2] + 1][col] then
					local pixel = pixels[mark[2] + 1][col]
					if details.url then
						pixel.url = details.url
					else
						pixel.style = vim.api.nvim_get_hl(0, { name = details.hl_group, link = false })
					end
				end
			end
		end
	end
	return { lines = lines, pixels = pixels }
end

local function stream(chunks)
	local buf = vim.api.nvim_create_buf(false, true)
	local tail, ctx = "", {}
	for _, chunk in ipairs(chunks) do
		local lines
		lines, tail = output.normalize(vim.split(chunk, "\n", { plain = true }), tail, {})
		ansi.buf_set_lines(buf, -2, -1, lines, true, ctx)
		s.drain()
	end
	return buf, ctx
end

describe("ANSI stream state", function()
	before_each(function()
		helpers.setup_tests({ ansi_color = { kind = "render" }, ansi_osc = { kind = "render" } })
	end)

	it("produces identical text, colors and links at every two-chunk boundary", function()
		local text = "\27[31mred\n\27[1mbold\27]8;;https://example.com\27\\link\ncontinued\27]8;;\27\\\27[0m done\n"
		local reference = stream({ text })
		local expected = snapshot(reference)
		assert.is_truthy(expected.pixels[2][1].style.bold)
		assert.equals(expected.pixels[1][1].style.fg, expected.pixels[2][1].style.fg)
		for split = 1, #text - 1 do
			local actual = stream({ text:sub(1, split), text:sub(split + 1) })
			assert.are.same(expected, snapshot(actual), "split byte " .. split)
			vim.api.nvim_buf_delete(actual, { force = true })
		end
	end)

	it("keeps an OSC ending in a split ST terminator hidden until complete", function()
		local buf, ctx = stream({ "before\27]8;;https://example.com\27" })
		assert.equals("before", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		ansi.buf_set_lines(buf, 0, 1, { "before\27]8;;https://example.com\27\\link\27]8;;\7" }, true, ctx)
		s.drain()
		assert.equals("beforelink", snapshot(buf).lines[1])
		assert.equals("https://example.com", snapshot(buf).pixels[1][7].url)
	end)

	it("carries color and links across a 128-line batch boundary", function()
		local lines = { "\27[34m\27]8;;https://example.com\7row 1" }
		for i = 2, 130 do
			lines[i] = "row " .. i
		end
		lines[130] = lines[130] .. "\27]8;;\7\27[0m"
		local whole = stream({ table.concat(lines, "\n") .. "\n" })
		local first, second = {}, {}
		for i, line in ipairs(lines) do
			table.insert(i <= 128 and first or second, line)
		end
		local split = stream({ table.concat(first, "\n") .. "\n", table.concat(second, "\n") .. "\n" })
		assert.are.same(snapshot(whole), snapshot(split))
	end)

	it("reuses custom handler text and side effects only for replayed OSC bytes", function()
		local calls = 0
		require("compile-mode.config.internal").ansi_osc.handlers = {
			[99] = function()
				calls = calls + 1
				return "replacement " .. calls
			end,
		}
		local buf = stream({ "\27]99;once\7a", "b", "c\n" })
		assert.equals(1, calls)
		assert.equals("replacement 1abc", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
	end)

	it("continues style after CR and executes a new identical OSC again", function()
		local calls = 0
		require("compile-mode.config.internal").ansi_osc.handlers = {
			[9] = function()
				calls = calls + 1
				return ""
			end,
		}
		local buf, ctx = stream({ "\27[31m\27]9;same\7progress" })
		local red = snapshot(buf).pixels[1][1].style.fg
		ctx.replay_prefix, ctx.replay_reset = 0, true
		ansi.buf_set_lines(buf, 0, 1, { "\27]9;same\7progress" }, true, ctx)
		s.drain()
		assert.equals(2, calls)
		assert.equals(red, snapshot(buf).pixels[1][1].style.fg)
		ctx.replay_prefix = #"\27]9;same\7progress"
		ansi.buf_set_lines(buf, 0, 1, { "\27]9;same\7progress more" }, true, ctx)
		s.drain()
		assert.equals(2, calls)
	end)

	it("processes control state discarded by same-batch carriage returns", function()
		local calls = 0
		require("compile-mode.config.internal").ansi_osc.handlers = {
			[9] = function()
				calls = calls + 1
				return ""
			end,
		}
		local buf = vim.api.nvim_create_buf(false, true)
		local ctx = {
			replay_reset = true,
			discarded_prefixes = { "\27[31m\27]9;once\7old\r", "\27[34mold\r" },
		}
		ansi.buf_set_lines(buf, 0, 1, { "red", "blue" }, true, ctx)
		s.drain()
		local actual = snapshot(buf)
		assert.equals(1, calls)
		assert.is_true(actual.pixels[1][1].style.fg ~= actual.pixels[2][1].style.fg)
		assert.are.same({ "red", "blue" }, actual.lines)
		assert.is_nil(ctx.discarded_prefixes)
	end)

	it("isolates stream colors, links and partial sequences while revisiting older rows", function()
		local buf = vim.api.nvim_create_buf(false, true)
		local stdout, stderr = {}, {}
		ansi.buf_set_lines(buf, 0, 1, { "\27[31m\27]8;;https://example.com\7out" }, true, stdout)
		s.drain()
		ansi.buf_set_lines(buf, 1, 1, { "err", "" }, true, stderr)
		s.drain()
		ansi.buf_set_lines(buf, 0, 1, { "\27[31m\27]8;;https://example.com\7output" }, true, stdout)
		s.drain()
		ansi.buf_set_lines(buf, 3, 3, { "continued\27]8;;\7\27[0m" }, true, stdout)
		s.drain()
		local actual = snapshot(buf)
		assert.are.same({}, actual.pixels[2][1])
		assert.equals(actual.pixels[1][1].style.fg, actual.pixels[4][1].style.fg)
		assert.equals("https://example.com", actual.pixels[4][1].url)
	end)

	it("flushes an incomplete sequence into the correct stream row and resets state", function()
		local buf = vim.api.nvim_create_buf(false, true)
		local stdout, stderr = {}, {}
		ansi.buf_set_lines(buf, 0, 1, { "out\27[" }, true, stdout)
		ansi.buf_set_lines(buf, 1, 1, { "err" }, true, stderr)
		s.drain()
		ansi.flush(buf, stdout)
		assert.are.same({ "out\27[", "err" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		ansi.reset(buf)
		ansi.buf_set_lines(buf, 0, -1, { "plain" }, true, stdout)
		s.drain()
		assert.are.same({}, snapshot(buf).pixels[1][1])
	end)

	it("preserves raw SGR bytes and computes OSC positions when stripping is disabled", function()
		require("compile-mode.config.internal").ansi_color.baleia_options = { strip_ansi_codes = false }
		local text = "\27[31mred\n\27]8;;https://example.com\7linked\27]8;;\7\27[0m"
		local whole = stream({ text })
		local split = stream({ "\27[31mred\n", "\27]8;;https://example.com\7linked\27]8;;\7\27[0m" })
		assert.are.same(snapshot(whole), snapshot(split))
		assert.equals("\27[31mred", snapshot(split).lines[1])
	end)
	it("respects the configured start column on inherited color rows", function()
		require("compile-mode.config.internal").ansi_color.baleia_options = { line_starts_at = 3 }
		local buf = stream({ "\27[31mfirst\n", "second" })
		local actual = snapshot(buf)
		assert.are.same({}, actual.pixels[2][1])
		assert.are.same({}, actual.pixels[2][2])
		assert.equals(actual.pixels[1][1].style.fg, actual.pixels[2][3].style.fg)
	end)

	it("keeps configured renderer logging and rejects incompatible private helpers", function()
		local create = require("compile-mode.ansi_render").create
		local messages = {}
		local renderer = { logger = {
			debug = function(message)
				messages[message] = true
			end,
		} }
		local adapter = assert(create({ name = "AnsiStreamLogger", log = "DEBUG" }, renderer))
		local buf = vim.api.nvim_create_buf(false, true)
		local text, _, spans, definitions = adapter.line("\27[31mred\27[0m")
		adapter.write(buf, 0, 1, { text })
		adapter.apply(buf, 0, { spans }, definitions)
		s.drain()
		assert.is_true(messages["vim.api.nvim_buf_set_lines"])
		assert.is_true(messages["vim.api.nvim_set_hl"])
		assert.is_true(messages["vim.api.nvim_buf_set_extmark"])
		local saved = package.loaded["baleia.styles"]
		package.loaded["baleia.styles"] = true
		local ok, result = pcall(create, { name = "UnsupportedStreamRenderer" }, renderer)
		package.loaded["baleia.styles"] = saved
		assert.is_true(ok)
		assert.is_nil(result)
	end)
end)
