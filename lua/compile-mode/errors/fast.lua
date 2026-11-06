-- Capture extraction for a deliberately narrow, common GNU diagnostic shape.
-- The native regex still decides whether/where it matches; unknown regex text,
-- filenames, source ranges and informational forms use the general extractor.
local gnu_regex = require("compile-mode.errors.matchers").gnu.regex
local M = {}

-- Every GNU source position contains a colon, at most one space, and a digit.
-- This also rejects long colon-terminated noise before entering Vim regexes.
function M.candidate(line, regex)
	return regex ~= gnu_regex or line:find(": ?[0-9]") ~= nil
end

---@param line string
---@param regex string
---@param rx vim.regex
---@return (CompileModeRange|nil)[]|nil
function M.captures(line, regex, rx)
	-- matchlist() observes ignorecase, while vim.regex() has separate flags.
	-- Retain the general extractor whenever those two operations can differ.
	if regex ~= gnu_regex or vim.o.ignorecase then
		return nil
	end
	local filename, row_start, row, after_row = line:match("^([%a_./][%w_./%-]*):()([0-9]+)()")
	if not filename or line:sub(after_row, after_row) ~= ":" then
		return nil
	end
	local after = after_row + 1
	local col, after_col = line:match("^([0-9]+)():", after)
	local col_start
	if col then
		col_start = after
		after = after_col + 1
	end
	if line:find("^[0-9]", after) then
		return nil
	end
	local word_start = line:match("^ *()", after)
	local suffix = line:sub(word_start)
	-- A later source position can make GNU's optional tool prefix consume the
	-- leading filename; let the native capture extractor resolve that ambiguity.
	if suffix:find(": ?[0-9]") then
		return nil
	end
	-- These branches have more complex captures or word-boundary semantics.
	if
		suffix:match("^[Ii]nfo")
		or suffix:match("^I:")
		or suffix:match("^%[ skipping ")
		or suffix:match("^instantiated from")
		or suffix:match("^required from")
		or suffix:match("^[Nn]ote")
	then
		return nil
	end
	local warning = suffix:match("^FutureWarning")
		or suffix:match("^RuntimeWarning")
		or suffix:match("^Warning")
		or suffix:match("^warning")
	local start, finish = rx:match_str(line)
	if not start then
		return {}
	end
	if start ~= 0 or (col and finish < after) then
		return nil
	end
	local result = {
		{ start = 1, end_ = finish },
		{ start = 1, end_ = #filename },
		{ start = row_start, end_ = row_start + #row - 1 },
	}
	if col then
		result[6] = { start = col_start, end_ = col_start + #col - 1 }
	end
	if warning then
		result[9] = { start = word_start, end_ = word_start + #warning - 1 }
	end
	return result
end

return M
