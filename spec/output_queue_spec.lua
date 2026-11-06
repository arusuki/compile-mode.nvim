---@diagnostic disable: duplicate-set-field -- Test doubles are restored after each case.
local assert = require("luassert")
local queues = require("compile-mode.output_queue")
local output = require("compile-mode.output")

describe("bounded output callback backlog", function()
	it("spools a large callback without losing delimiters, empty entries or stream order", function()
		local queue = queues.new()
		local data = {}
		for i = 1, 3000 do
			data[i] = tostring(i) .. string.rep("x", 1024)
		end
		data[#data + 1] = ""
		queue.push("stdout", data)
		queue.push("stderr", { "other\nencoded-nul", "" })
		assert.is_true(queue.peak_bytes <= 1024 * 1024)
		local rows, partial, streams = {}, "", {}
		while not queue.empty() do
			local item = _G.assert(queue.pop())
			streams[#streams + 1] = item.stream
			if item.stream == "stdout" then
				local normalized
				normalized, partial = output.normalize(item.data, partial, {})
				for i = 1, #normalized - 1 do
					rows[#rows + 1] = normalized[i]
				end
			else
				assert.are.same({ "other\nencoded-nul", "" }, item.data)
			end
		end
		assert.are.equal(3000, #rows)
		for i = 1, #rows do
			assert.are.equal(data[i], rows[i])
		end
		assert.are.equal("stderr", streams[#streams])
		assert.are.equal(0, queue.bytes)
		queue.close()
	end)

	it("closes temporary files both after consumption and after cancellation", function()
		local original, files = io.tmpfile, {}
		io.tmpfile = function()
			local file = assert(original())
			files[#files + 1] = file
			return file
		end
		local ok, reason = pcall(function()
			local drained = queues.new()
			drained.push("stdout", { string.rep("a", 2 * 1024 * 1024) })
			drained.pop()
			assert.are.equal("closed file", io.type(files[1]))
			local cancelled = queues.new()
			cancelled.push("stderr", { string.rep("b", 2 * 1024 * 1024) })
			cancelled.close()
			assert.are.equal("closed file", io.type(files[2]))
			assert.is_true(cancelled.empty())
		end)
		io.tmpfile = original
		assert.is_true(ok, reason)
	end)

	it("tracks retained raw prefixes after hidden-output deletion and carriage returns", function()
		local _, _, replay = output.normalize({ "tail" }, "\27]9;notice\7head", {})
		assert.are.equal(#"\27]9;notice\7head", replay.prefix)
		assert.is_false(replay.reset)
		_, _, replay = output.normalize({ "new" }, "old\r", {})
		assert.are.same({ prefix = 0, reset = true, discarded = "", discarded_prefixes = { "" } }, replay)
		_, _, replay = output.normalize({ "tail" }, "hide-head", { "hide-" })
		assert.are.same({ prefix = 4, reset = false }, replay)
		_, _, replay = output.normalize({ "tail" }, "before\rnotice", { "unmatched" })
		assert.are.same({ prefix = 6, reset = false }, replay)
		_, _, replay = output.normalize({ "\27[31m100\r200" }, "", {})
		assert.are.same(
			{ prefix = 0, reset = true, discarded = "\27[31m100\r", discarded_prefixes = { "\27[31m100\r" } },
			replay
		)
	end)
end)
