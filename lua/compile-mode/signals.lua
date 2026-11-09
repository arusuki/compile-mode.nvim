local M = {}

function M.complete(prefix)
	local names = {}
	for name in pairs(vim.uv.constants) do
		if
			name:match("^SIG[A-Z0-9]+$")
			and (name:sub(4):sub(1, #prefix) == prefix:upper() or name:sub(1, #prefix) == prefix:upper())
		then
			names[#names + 1] = name:sub(4)
		end
	end
	table.sort(names)
	return names
end

---Send to the job's own process group, never the editor's process group.
---@param job integer
---@param signal string|integer
---@return boolean, string?
function M.send(job, signal)
	if vim.fn.has("win32") == 1 then
		return false, "Unix process-group signals are not supported on Windows"
	end
	local number = tonumber(signal)
	if not number then
		local name = tostring(signal):upper():gsub("^SIG", "")
		number = vim.uv.constants["SIG" .. name]
	end
	local valid = number ~= nil and number > 0 and number == math.floor(number)
	for name, value in pairs(vim.uv.constants) do
		if name:match("^SIG[A-Z0-9]+$") and value == number then
			valid = true
		end
	end
	if not valid then
		return false, "Unsupported signal: " .. tostring(signal)
	end
	local ok, err = pcall(function()
		local pid = vim.fn.jobpid(job)
		local ffi = require("ffi")
		ffi.cdef("int getpgid(int pid);")
		local group = tonumber(ffi.C.getpgid(pid))
		-- Neovim launches jobs as process-group leaders. Refuse changed or
		-- unexpected groups instead of risking signalling the editor itself.
		assert(
			pid > 1 and group == pid and group ~= tonumber(ffi.C.getpgid(0)),
			"Unsafe or unavailable job process group"
		)
		local result, reason = vim.uv.kill(-group, number)
		assert(result == 0, reason)
	end)
	return ok, not ok and tostring(err) or nil
end

return M
