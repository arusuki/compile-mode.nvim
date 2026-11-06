local assert = require("luassert")
local output = require("compile-mode.output")

local function replace(displayed, lines)
	if #lines == 0 then
		return
	end
	displayed[#displayed] = nil
	vim.list_extend(displayed, lines)
end

describe("fragmented output stream", function()
	it("keeps short lines, blank lines, NULs, and pending CRs live", function()
		local chunks = {
			{ "he\nllo" },
			{ "\r" },
			{ "\r\n" },
			{ "world", "", "ab" },
			{ "c\r\r" },
			{ "d\re", "last" },
		}
		for _, hidden in ipairs({ {}, { "world", "abc\r\rd" } }) do
			local stream, tail = output.new_stream(hidden), ""
			for _, chunk in ipairs(chunks) do
				local expected
				expected, tail = output.normalize(chunk, tail, hidden)
				assert.are.same(expected, stream.push(chunk))
			end
			assert.are.same({}, stream.flush())
		end
	end)

	it("bounds replayed prefixes and flushes an unterminated long line", function()
		local stream = output.new_stream({})
		local prefix, chunk = string.rep("a", 65536), string.rep("b", 256)
		local displayed = { "" }
		local writes, bytes = 0, 0
		local function consume(lines)
			replace(displayed, lines)
			for _, line in ipairs(lines) do
				writes, bytes = writes + 1, bytes + #line
			end
		end
		consume(stream.push({ prefix }))
		for _ = 1, 4000 do
			consume(stream.push({ chunk }))
		end
		assert.is_true(stream.has_pending())
		consume(stream.flush())
		local expected = prefix .. string.rep(chunk, 4000)
		assert.are.same({ expected }, displayed)
		assert.is_true(writes <= 7, "too many complete-prefix writes: " .. writes)
		assert.is_true(bytes < 3 * #expected, "replayed bytes must grow linearly")
		assert.is_false(stream.has_pending())
		assert.are.same({}, stream.flush())
	end)

	it("counts hidden raw bytes and preserves patterns across deferred CR history", function()
		local hidden = { "secret\rpublic", "^x\\+$" }
		local stream = output.new_stream(hidden)
		local prefix = string.rep("x", 65536)
		assert.are.same({ "" }, stream.push({ prefix }))
		for _ = 1, 1000 do
			assert.are.same({}, stream.push({ "x" }))
		end
		assert.are.same({}, stream.push({ "secret\r" }))
		local expected = output.normalize({ "public", "" }, prefix .. string.rep("x", 1000) .. "secret\r", hidden)
		assert.are.same(expected, stream.push({ "public", "" }))
	end)

	it("returns to live updates when CR overwrites a deferred long tail", function()
		local stream = output.new_stream({})
		stream.push({ string.rep("x", 65536) })
		assert.are.same({}, stream.push({ string.rep("x", 1000) .. "\r" }))
		assert.are.same({ "1%" }, stream.push({ "1%\r" }))
		assert.are.same({ "2%" }, stream.push({ "\r2%\r" }))
		assert.are.same({ "done", "" }, stream.push({ "done", "" }))
	end)

	it("defers CR-only fragments until an overwrite without losing replay metadata", function()
		local stream = output.new_stream({})
		local prefix = string.rep("x", 65536)
		stream.push({ prefix })
		for _ = 1, 1000 do
			assert.are.same({}, stream.push({ "\r\n" }))
		end
		local lines, tail, replay = stream.push({ "done" })
		assert.are.same({ "done" }, lines)
		assert.are.equal("done", tail)
		assert.is_true(replay.reset)
		assert.are.equal(0, replay.prefix)
		assert.are.equal(string.rep("\r", 1000), replay.discarded)
	end)

	it("finishes each deferred line and preserves later output in the same batch", function()
		local stream = output.new_stream({})
		local prefix = string.rep("x", 65536)
		stream.push({ prefix })
		assert.are.same({}, stream.push({ "suffix" }))
		assert.are.same({ prefix .. "suffix!", "", "next" }, stream.push({ "!", "", "next" }))
		assert.are.same({ "next!" }, stream.push({ "!" }))
	end)

	it("preserves final text under deterministic mixed chunking and hidden patterns", function()
		local seed = 17
		local function random(n)
			seed = (seed * 48271) % 2147483647
			return seed % n + 1
		end
		for _, hidden in ipairs({ {}, { "secret\rpublic", "hide\\d\\+" } }) do
			local stream, tail = output.new_stream(hidden), ""
			local actual, expected = { "" }, { "" }
			local alphabet = { "x", "secret\r", "public", "\n", "\r", "\27[", "31m", "hide12" }
			for i = 1, 1600 do
				local chunk = i <= 350 and { string.rep("x", 256) } or { alphabet[random(#alphabet)] }
				if i > 350 and random(12) == 1 then
					chunk[2] = ""
				end
				local lines
				lines, tail = output.normalize(chunk, tail, hidden)
				replace(expected, lines)
				replace(actual, stream.push(chunk))
			end
			replace(actual, stream.flush())
			assert.are.same(expected, actual)
		end
	end)
end)
