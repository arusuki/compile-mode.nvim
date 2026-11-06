-- Additional necessary conditions for expensive builtin rules. These are only
-- rejection tests: the original Vim regex still decides matches and captures.
-- Key by exact regex text, never by the user-configurable matcher name.
local builtins = require("compile-mode.errors.matchers")
local checks = {
	[builtins.cucumber.regex] = function(line)
		-- The two branches are an anchored cucumber command or an unanchored
		-- '#', both followed by one literal space. Include case-folded forms
		-- conservatively rather than depending on the editor's case options.
		return line:find("# ", 1, true) ~= nil or line:find("^[Cc][Uu][Cc][Uu][Mm][Bb][Ee][Rr] ") ~= nil
	end,
	[builtins.absoft.regex] = function(line)
		-- Optional Error/Warning prefix, otherwise Line; all alternatives are
		-- anchored. A first-byte test avoids even scanning a long nonmatch.
		local first = line:byte(1)
		return first == 69 or first == 101 or first == 87 or first == 119 or first == 76 or first == 108
	end,
	[builtins.borland.regex] = function(line)
		return line:find("^[Ee][Rr][Rr][Oo][Rr] ") ~= nil or line:find("^[Ww][Aa][Rr][Nn][Ii][Nn][Gg] ") ~= nil
	end,
}

local M = {}

---@param line string
---@param regex string
---@return boolean
function M.matches(line, regex)
	local check = checks[regex]
	return not check or check(line)
end

return M
