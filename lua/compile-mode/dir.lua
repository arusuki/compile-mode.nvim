local M = {}

local utils = require("compile-mode.utils")

---
---The previous directory used for compilation.
---@type string|nil
M.compilation_directory = nil

---A table which keeps track of the changes in directory for the compilation buffer,
---based on "Entering directory" and "Leaving directory" messages.
---@type table<integer, string>
M.dir_changes = {}

local indexed_changes
local change_lines = {}
local inserted_lines = {}
local revision = 0

local function lower_bound(lines, line)
	local first, last = 1, #lines + 1
	while first < last do
		local middle = math.floor((first + last) / 2)
		if lines[middle] < line then
			first = middle + 1
		else
			last = middle
		end
	end
	return first
end

local function ensure_index()
	if indexed_changes == M.dir_changes then
		return
	end
	indexed_changes = M.dir_changes
	inserted_lines = {}
	change_lines = vim.tbl_keys(M.dir_changes)
	table.sort(change_lines)
	revision = revision + 1
end

---Invalidate after an external in-place edit of the legacy directory table.
---Replacing the entire table is detected automatically.
function M.invalidate()
	indexed_changes = nil
end

---Set or remove a directory transition, keeping the ordered index current.
---@param line integer
---@param directory? string
function M.set_directory(line, directory)
	ensure_index()
	local previous = M.dir_changes[line]
	if previous == directory then
		return
	end
	if previous == nil then
		local lines = change_lines
		if #inserted_lines > 0 or (#change_lines > 0 and line < change_lines[#change_lines]) then
			-- Keep newly parsed prefixes separate from retained suffixes.
			-- A scan adds transitions in ascending order, without moving the
			-- retained directory index for every inserted line.
			lines = inserted_lines
		end
		table.insert(lines, lower_bound(lines, line), line)
	elseif directory == nil then
		for _, lines in ipairs({ change_lines, inserted_lines }) do
			local position = lower_bound(lines, line)
			if lines[position] == line then
				table.remove(lines, position)
			end
		end
	end
	M.dir_changes[line] = directory
	revision = revision + 1
end

---Remove metadata for an inclusive output-line range with one index compaction.
---@param first integer
---@param last integer
function M.clear_range(first, last)
	if first > last then
		return
	end
	ensure_index()
	local changed = false
	for _, lines in ipairs({ change_lines, inserted_lines }) do
		local start = lower_bound(lines, first)
		local finish = lower_bound(lines, last + 1)
		for i = start, finish - 1 do
			M.dir_changes[lines[i]] = nil
			changed = true
		end
		local removed = finish - start
		if removed > 0 then
			local length = #lines
			for i = finish, length do
				lines[i - removed] = lines[i]
			end
			for i = length - removed + 1, length do
				lines[i] = nil
			end
		end
	end
	if changed then
		revision = revision + 1
	end
end

---@return integer
function M.version()
	ensure_index()
	return revision
end

local function preceding(lines, linenum)
	local position = lower_bound(lines, linenum) - 1
	-- Read current values so legacy overwrites of existing transitions
	-- remain visible to uncached lookup/export callers.
	while position > 0 do
		local line = lines[position]
		local directory = M.dir_changes[line]
		if directory then
			return line, directory
		end
		position = position - 1
	end
	return 0, nil
end

---Get the directory to look in for a specific line in the compilation buffer,
---while respecting "Entering directory" and "Leaving directory" messages.
---@param linenum integer the line number to check the directory for
---@return string
function M.find_directory_for_line(linenum)
	ensure_index()
	if #change_lines == 0 and #inserted_lines == 0 then
		return M.compilation_directory or vim.fn.getcwd()
	end

	local original_line, original_directory = preceding(change_lines, linenum)
	local inserted_line, inserted_directory = preceding(inserted_lines, linenum)
	if original_line > inserted_line then
		return original_directory
	elseif inserted_directory then
		return inserted_directory
	end
	return M.compilation_directory or vim.fn.getcwd()
end

function M.resolve_filename(filename, linenum)
	if not linenum or utils.is_absolute(filename) then
		return filename
	end

	local dir = M.find_directory_for_line(linenum)
	return vim.fs.joinpath(dir, filename)
end

return M
