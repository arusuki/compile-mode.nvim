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
