local utils = require("compile-mode.utils")
local cdir = require("compile-mode.dir")
local prefilters = require("compile-mode.errors.prefilters")

local M = {}

M.level = require("compile-mode.constants").level

---@type table<integer, CompileModeError>
M.error_list = {}

M.error_regexp_table = require("compile-mode.errors.matchers")

---Given a `matchlistpos` result and a capture-group matcher, return the location of the relevant capture group(s).
---
---@param result (CompileModeRange|nil)[]
---@param group integer|CompileModeIntByInt|nil
---@return CompileModeRange|nil
---@return CompileModeRange|nil
local function parse_matcher_group(result, group)
	if not group then
		return nil
	elseif type(group) == "number" then
		return result[group + 1]
	elseif type(group) == "table" then
		local first = group[1] + 1
		local second = group[2] + 1

		return result[first], result[second]
	end
end

---Get the range and its value from a certain line
---@param line string
---@param range CompileModeRange
---@return CompileModeValueAndRange<string>
local function range_and_value(line, range)
	return {
		value = line:sub(range.start, range.end_),
		range = range,
	}
end

---Get the range and its numeric value, if it contains a number.
---@param line string
---@param range CompileModeRange|nil
---@return CompileModeValueAndRange<number>|nil
local function numeric_range_and_value(line, range)
	if not range then
		return nil
	end

	local raw = range_and_value(line, range)
	local parsed = tonumber(raw.value)
	if not parsed then
		return nil
	end
	return { value = parsed, range = raw.range }
end

---Parse a line for errors using a specific matcher from `error_regexp_table`.
---@param matcher CompileModeRegexpMatcher|nil
---@param line string
---@param linenum integer
---@return CompileModeError|nil
local function parse_matcher(matcher, line, linenum)
	if not matcher then
		return nil
	end

	matcher._rx = matcher._rx or vim.regex(matcher.regex)

	local result = utils.matchlistpos(line, matcher.regex, matcher._rx)
	if not result then
		return nil
	end

	local filename_range = result[matcher.filename + 1]
	if not filename_range then
		return nil
	end

	local row_range, end_row_range = parse_matcher_group(result, matcher.row)
	local col_range, end_col_range = parse_matcher_group(result, matcher.col)

	---@type CompileModeLevel
	local error_level
	local matcher_type = matcher.type
	if matcher_type == nil then
		error_level = M.level.ERROR
	elseif type(matcher_type) == "number" then
		error_level = matcher_type
	elseif type(matcher_type) == "table" then
		if result[matcher_type[1] + 1] then
			error_level = M.level.WARNING
		elseif matcher_type[2] and result[matcher_type[2] + 1] then
			error_level = M.level.INFO
		else
			error_level = M.level.ERROR
		end
	end

	---@type CompileModeError
	return {
		highlighted = false,
		level = error_level,
		priority = matcher.priority or 1,
		full = result[1],
		full_text = line,
		filename = range_and_value(line, filename_range),
		row = numeric_range_and_value(line, row_range),
		col = numeric_range_and_value(line, col_range),
		end_row = numeric_range_and_value(line, end_row_range),
		end_col = numeric_range_and_value(line, end_col_range),
		group = nil,
		linenum = linenum,
	}
end

---@param error CompileModeError
---@return unknown
local function map_to_qflist(error)
	local lnum = error.row and error.row.value
	return {
		filename = cdir.resolve_filename(error.filename.value, error.linenum),
		lnum = lnum,
		end_lnum = error.end_row and error.end_row.value,
		col = error.col and error.col.value,
		end_col = error.end_col and error.end_col.value,
		text = error.full_text,
	}
end

---@param error_list table<integer, CompileModeError> table of compilation errors, usually `errors.error_list`
---@return unknown[] qflist values which can be inserted into the quickfix list using `setqflist()`
function M.toqflist(error_list)
	local config = require("compile-mode.config.internal")

	return vim.iter(vim.tbl_values(error_list))
		:filter(function(error)
			return error.level >= config.error_threshold
		end)
		:map(map_to_qflist)
		:totable()
end

---@param bufnr integer
---@param error CompileModeError
---@return vim.Diagnostic
local function map_to_diagnostic(bufnr, error)
	---@type vim.diagnostic.Severity
	local level
	if error.level == M.level.ERROR then
		level = vim.diagnostic.severity.ERROR
	elseif error.level == M.level.WARNING then
		level = vim.diagnostic.severity.ERROR
	else
		level = vim.diagnostic.severity.INFO
	end

	local col = error.col and error.col.value - 1 or 0
	local lnum = error.row.value - 1

	---@type vim.Diagnostic
	return {
		bufnr = bufnr,
		col = col,
		lnum = lnum,
		message = error.full_text,
		severity = level,
		end_col = error.end_col and error.end_col.value - 1 or col,
		end_lnum = error.end_row and error.end_row.value - 1 or lnum,
	}
end

---@param error_list table<integer, CompileModeError> table of compilation errors, usually `errors.error_list`
---@return vim.Diagnostic[]
function M.todiagnostic(bufnr, error_list)
	local buffers = {}
	local diagnostics = {}
	for _, error in pairs(error_list) do
		-- Filename-only messages are useful in quickfix, but have no source
		-- position to attach a diagnostic to.
		if error.row then
			local resolved = cdir.resolve_filename(error.filename.value, error.linenum)
			local error_buf = buffers[resolved]
			if not error_buf then
				error_buf = vim.fn.bufadd(resolved)
				buffers[resolved] = error_buf
			end
			if error_buf == bufnr then
				diagnostics[#diagnostics + 1] = map_to_diagnostic(bufnr, error)
			end
		end
	end
	return diagnostics
end

local _ordered = nil
local _ordered_table = nil
local function get_ordered(config)
	if _ordered and _ordered_table == config.error_regexp_table then
		return _ordered
	end

	_ordered_table = config.error_regexp_table
	_ordered = {}
	for group, matcher in pairs(config.error_regexp_table) do
		---@cast matcher CompileModeRegexpMatcher
		table.insert(_ordered, { group = group, matcher = matcher, literal = prefilters[matcher.regex] })
	end

	table.sort(_ordered, function(a, b)
		local pa = a.matcher.priority or 0
		local pb = b.matcher.priority or 0
		if pa ~= pb then
			return pa > pb
		end
		return tostring(a.group) < tostring(b.group)
	end)

	return _ordered
end

---Parses error syntax from a given line.
---@param line string the line to parse
---@param linenum integer the line number of the parsed line
---@return CompileModeError|nil
function M.parse(line, linenum)
	local config = require("compile-mode.config.internal")

	local ordered = get_ordered(config)
	local present = {}
	for _, item in ipairs(ordered) do
		local literal = item.literal
		if literal and present[literal] == nil then
			present[literal] = line:find(literal, 1, true) ~= nil
		end
		local result = (not literal or present[literal]) and parse_matcher(item.matcher, line, linenum)
		if result then
			result.group = item.group

			local ignored = false
			for _, pattern in ipairs(config.error_ignore_file_list or {}) do
				if vim.fn.match(result.filename.value, pattern) ~= -1 then
					ignored = true
					break
				end
			end

			if not ignored then
				return result
			end
		end
	end

	return nil
end

---Highlight a single error in the compilation buffer.
---@param bufnr integer
---@param error CompileModeError
---@param linenum integer
local function highlight_error(bufnr, error, linenum)
	if error.highlighted then
		return
	end

	error.highlighted = true

	local full_range = error.full
	utils.add_highlight(bufnr, "CompileModeMessage", linenum, full_range)

	local hlgroup = "CompileMode"
	if error.level == M.level.WARNING then
		hlgroup = hlgroup .. "Warning"
	elseif error.level == M.level.INFO then
		hlgroup = hlgroup .. "Info"
	else
		hlgroup = hlgroup .. "Error"
	end

	local filename_range = error.filename.range
	utils.add_highlight(bufnr, hlgroup, linenum, filename_range)

	local row_range = error.row and error.row.range
	if row_range then
		utils.add_highlight(bufnr, "CompileModeMessageRow", linenum, row_range)
	end
	local end_row_range = error.end_row and error.end_row.range
	if end_row_range then
		utils.add_highlight(bufnr, "CompileModeMessageRow", linenum, end_row_range)
	end

	local col_range = error.col and error.col.range
	if col_range then
		utils.add_highlight(bufnr, "CompileModeMessageCol", linenum, col_range)
	end
	local end_col_range = error.end_col and error.end_col.range
	if end_col_range then
		utils.add_highlight(bufnr, "CompileModeMessageCol", linenum, end_col_range)
	end
end

---Highlight the selected errors, or all errors when no selection is supplied.
---A deferred scan result must not restore highlights for a replaced error.
---@param bufnr integer
---@param selected? table<integer, CompileModeError>
function M.highlight(bufnr, selected)
	for linenum, error in pairs(selected or M.error_list) do
		if M.error_list[linenum] == error then
			highlight_error(bufnr, error, linenum)
		end
	end
end

return M
