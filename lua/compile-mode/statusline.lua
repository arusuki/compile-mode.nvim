local errors = require("compile-mode.errors")

local M = {}

local exit_code = require("compile-mode.constants").exit_code

---@class CompileModeStatuslineInfo
---@field counts {error: integer, warning: integer, info: integer}
---@field status {type: "run"}|{type:"exit", code: integer}|nil

---@return CompileModeStatuslineInfo
function M.info()
	local info = {
		status = nil,
		counts = errors.counts(),
	}

	if vim.g.compile_job_id then
		info.status = { type = "run" }
	elseif vim.g.compilation_exit_code then
		info.status = { type = "exit", code = vim.g.compilation_exit_code }
	end

	return info
end

function M.format(colors)
	if vim.bo.filetype ~= "compilation" and not vim.g.compile_job_id and not vim.g.compilation_exit_code then
		return ""
	end

	colors = colors and colors ~= 0

	local info = M.info()

	local status_text
	if not info.status then
		status_text = ""
	elseif info.status.type == "run" then
		status_text = ":run"
		if colors then
			status_text = "%#CompileModeCheckTarget#" .. status_text .. "%*"
		end
	elseif info.status.type == "exit" then
		status_text = (":exit [%d]"):format(info.status.code)
		if colors then
			local color = info.status.code == exit_code.SUCCESS and "%#CompileModeInfo#" or "%#CompileModeError#"
			status_text = color .. status_text .. "%*"
		end
	end

	local error_count = ("%d"):format(info.counts.error)
	if colors then
		error_count = "%#CompileModeError#" .. error_count .. "%*"
	end
	local warning_count = ("%d"):format(info.counts.warning)
	if colors then
		warning_count = "%#CompileModeWarning#" .. warning_count .. "%*"
	end
	local info_count = ("%d"):format(info.counts.info)
	if colors then
		info_count = "%#CompileModeInfo#" .. info_count .. "%*"
	end

	return ("Compilation%s [%s %s %s]"):format(status_text, error_count, warning_count, info_count)
end

return M
