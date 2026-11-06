-- Buffer layout and process exit codes shared by the runtime modules.
local M = {}

M.header_line_count = 4

-- See :h on_exit: signals are reported as 128 + signal number.
M.exit_code = {
	SUCCESS = 0,
	SIGSEGV = 139,
	SIGTERM = 143,
}

---@enum CompileModeLevel
M.level = {
	ERROR = 2,
	WARNING = 1,
	INFO = 0,
}

return M
