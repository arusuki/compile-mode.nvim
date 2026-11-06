-- Transform job callback data before ANSI processing or buffer writes.
local header_line_count = require("compile-mode.constants").header_line_count
local M = {}

---Join the unfinished line, remove encoded NULs, filter hidden output, and handle CRs.
---The returned tail is captured before filtering so a later chunk can be reprocessed.
---The input table is not modified. Callers skip empty/EOF callbacks before calling.
---@param data string[]
---@param partial_line string
---@param hidden_output string[]
---@return string[] lines
---@return string partial_line
function M.normalize(data, partial_line, hidden_output)
	local new_lines = { partial_line .. (data[1]:gsub("\n", "")) }
	for i = 2, #data do
		table.insert(new_lines, (data[i]:gsub("\n", "")))
	end
	partial_line = new_lines[#new_lines]

	for i, line in ipairs(new_lines) do
		for _, re in ipairs(hidden_output) do
			line = vim.fn.substitute(line, re, "", "")
			new_lines[i] = line
		end

		while vim.endswith(line, "\r") do
			line = line:sub(0, -2)
		end

		local last_carriage_return = vim.fn.strridx(line, "\r")
		if last_carriage_return >= 0 and last_carriage_return < line:len() - 1 then
			line = line:sub(last_carriage_return + 2, -1)
		end

		new_lines[i] = line
	end
	return new_lines, partial_line
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
