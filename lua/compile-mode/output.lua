-- Transform job callback data before ANSI processing or buffer writes.
local header_line_count = require("compile-mode.constants").header_line_count
local M = {}

---Join the unfinished line, remove encoded NULs, filter hidden output, and handle CRs.
---Without hidden patterns, keep only the visible tail and one pending carriage return.
---Hidden patterns can match across CRs, so their raw tail must remain replayable.
---The input table is not modified. Callers skip empty/EOF callbacks before calling.
---@param data string[]
---@param partial_line string
---@param hidden_output string[]
---@return string[] lines
---@return string partial_line
---@return {prefix: integer, reset: boolean, discarded?: string, discarded_prefixes?: table<integer, string>} replay
function M.normalize(data, partial_line, hidden_output)
	local replay = { prefix = #partial_line, reset = false }
	local new_lines = { partial_line .. (data[1]:gsub("\n", "")) }
	for i = 2, #data do
		table.insert(new_lines, (data[i]:gsub("\n", "")))
	end
	partial_line = new_lines[#new_lines]
	local compact_tail = #hidden_output == 0

	for i, line in ipairs(new_lines) do
		for _, re in ipairs(hidden_output) do
			if i == 1 and replay.prefix > 0 then
				local match = vim.fn.matchstrpos(line, re)
				if match[2] >= 0 and match[2] < replay.prefix then
					replay.prefix = replay.prefix - (math.min(match[3], replay.prefix) - match[2])
				end
			end
			line = vim.fn.substitute(line, re, "", "")
			new_lines[i] = line
		end

		local last = #line
		while last > 0 and line:byte(last) == 13 do
			last = last - 1
		end
		local pending_cr = last < #line
		line = line:sub(1, last)
		if i == 1 then
			replay.prefix = math.min(replay.prefix, last)
		end
		local last_carriage_return = line:find("\r", 1, true) and line:match("^.*()\r")
		if last_carriage_return then
			if i == 1 then
				replay.reset = last_carriage_return >= replay.prefix
				if replay.reset then
					replay.discarded = line:sub(replay.prefix + 1, last_carriage_return)
					replay.discarded_prefixes = replay.discarded_prefixes or {}
					replay.discarded_prefixes[i] = replay.discarded
				end
				replay.prefix = math.max(0, replay.prefix - last_carriage_return)
			else
				replay.discarded_prefixes = replay.discarded_prefixes or {}
				replay.discarded_prefixes[i] = line:sub(1, last_carriage_return)
			end
			line = line:sub(last_carriage_return + 1)
		end
		if compact_tail and i == #new_lines then
			partial_line = line .. (pending_cr and "\r" or "")
		end

		new_lines[i] = line
	end
	return new_lines, partial_line, replay
end

---Collect a stream's unfinished line without replaying every growing prefix.
---Retain unpublished bytes verbatim so normalize() can distinguish replayed OSC
---events from new controls, including controls discarded by a carriage return.
---@param hidden_output string[]
---@return CompileModeOutputStream
function M.new_stream(hidden_output)
	local threshold = 65536
	local published, fragments, pending_bytes = "", {}, 0
	local next_flush, pending_cr = threshold, false
	local compact = #hidden_output == 0

	local function publish(data)
		if #fragments > 0 then
			fragments[#fragments + 1] = data[1]
			data[1] = table.concat(fragments)
		end
		local lines, tail, replay = M.normalize(data, published, hidden_output)
		published, fragments, pending_bytes = tail, {}, 0
		next_flush = math.max(threshold, #tail * 2)
		pending_cr = tail:sub(-1) == "\r"
		return lines, tail, replay
	end

	---@class CompileModeOutputStream
	local stream = {}

	---Return normalized replacement lines and replay metadata, or no lines while deferred.
	---@param data string[]
	---@return string[]
	---@return string partial_line
	---@return table replay
	function stream.push(data)
		-- Newlines finish the old tail. Normalize ordinary batches directly,
		-- preserving the original single-pass path and its ANSI replay contract.
		if #data > 1 or (#fragments == 0 and #published + #data[1] <= threshold) then
			return publish(vim.list_slice(data))
		end

		local text = data[1]:gsub("\n", "") -- callback-encoded NUL bytes
		local overwrite = false
		if compact and text ~= "" then
			local last = #text
			while last > 0 and text:byte(last) == 13 do
				last = last - 1
			end
			-- A CR becomes effective only when subsequent text arrives. Let the
			-- normalizer see all pending controls before discarding the old text.
			overwrite = last > 0 and (pending_cr or text:sub(1, last):find("\r", 1, true) ~= nil)
			pending_cr = last < #text
		end
		if text ~= "" then
			fragments[#fragments + 1] = text
			pending_bytes = pending_bytes + #text
		end
		if overwrite or #published + pending_bytes >= next_flush then
			return publish({ "" })
		end
		return {}, published, { prefix = #published, reset = false }
	end

	---Publish deferred EOF text before parsing/completion, even without a newline.
	---@return string[]
	---@return string partial_line
	---@return table replay
	function stream.flush()
		if #fragments > 0 then
			return publish({ "" })
		end
		return {}, published, { prefix = #published, reset = false }
	end

	function stream.has_pending()
		return #fragments > 0
	end

	return stream
end

---Limit replacement of the buffer's unfinished last line to the output budget.
---@param lines string[]
---@param line_count integer current buffer line count, including the header
---@param max_lines? integer
---@return string[] lines
---@return boolean exceeded
function M.limit(lines, line_count, max_lines)
	if not max_lines then
		return lines, false
	end

	local available = max_lines + header_line_count - (line_count - 1)
	if available <= 0 then
		return {}, true
	elseif #lines > available then
		return vim.list_slice(lines, 1, available), true
	end
	return lines, false
end

return M
