-- Keep callback backlog bounded in Lua memory. Overflow is a FIFO temporary
-- file, encoded a line at a time so one huge callback needs no second huge string.
local M = {}
local MAX_BYTES = 1024 * 1024
local MAX_RECORDS = 1024
local BATCH_BYTES = 65536
local BATCH_LINES = 128

function M.new()
	local queue = { bytes = 0, records = 0, peak_bytes = 0 }
	local memory, head, tail = {}, 1, 0
	local file, read_offset, write_offset = nil, 0, 0
	local closed = false

	local function enqueue(stream, data, bytes)
		local cost = bytes + #data * 24 + 64
		if not file and queue.bytes + cost <= MAX_BYTES and queue.records < MAX_RECORDS then
			tail = tail + 1
			memory[tail] = { stream = stream, data = data, cost = cost, bytes = bytes }
			queue.bytes = queue.bytes + cost
			queue.records = queue.records + 1
			queue.peak_bytes = math.max(queue.peak_bytes, queue.bytes)
			return
		end
		if not file then
			file = assert(io.tmpfile())
			read_offset, write_offset = 0, 0
		end
		assert(file:seek("set", write_offset))
		assert(file:write(stream, "\n", tostring(#data), "\n"))
		for _, value in ipairs(data) do
			assert(file:write(tostring(#value), "\n", value))
		end
		write_offset = assert(file:seek())
	end

	function queue.push(stream, data)
		assert(not closed, "output queue is closed")
		local index, length = 1, #data
		while index <= length do
			local chunk, bytes = {}, 0
			while index <= length and #chunk < BATCH_LINES and bytes < BATCH_BYTES do
				local value = data[index]
				chunk[#chunk + 1] = value
				bytes = bytes + #value
				index = index + 1
			end
			if index <= length then
				-- Preserve the newline before the next slice's first entry.
				chunk[#chunk + 1] = ""
			end
			enqueue(stream, chunk, bytes)
		end
	end

	function queue.empty()
		return head > tail and not file
	end

	function queue.pop()
		if head <= tail then
			local item = memory[head]
			memory[head] = nil
			head = head + 1
			queue.bytes = queue.bytes - item.cost
			queue.records = queue.records - 1
			if head > tail then
				memory, head, tail = {}, 1, 0
			end
			return item
		end
		if not file then
			return nil
		end
		assert(file:seek("set", read_offset))
		local stream = assert(file:read("*l"))
		local count = assert(tonumber(file:read("*l")))
		local data, bytes = {}, 0
		for i = 1, count do
			local length = assert(tonumber(file:read("*l")))
			data[i] = length == 0 and "" or assert(file:read(length))
			bytes = bytes + length
		end
		read_offset = assert(file:seek())
		if read_offset == write_offset then
			file:close()
			file = nil
		end
		return { stream = stream, data = data, bytes = bytes }
	end

	function queue.close()
		closed = true
		memory, head, tail = {}, 1, 0
		queue.bytes, queue.records = 0, 0
		if file then
			file:close()
			file = nil
		end
	end

	return queue
end

return M
