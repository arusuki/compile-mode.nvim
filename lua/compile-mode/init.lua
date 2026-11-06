---@alias SplitModifier
---|"aboveleft"
---|"belowright"
---|"topleft"
---|"botright"
---|""

---@class SMods
---
---@field vertical?   boolean
---@field silent?     boolean
---@field hide?       boolean
---@field tab?        integer
---@field split?      SplitModifier
---@field noswapfile? boolean

---@class CommandParam
---
---@field args?  string
---@field smods? SMods
---@field bang?  boolean
---@field count? integer

local a = require("plenary.async")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local log = require("compile-mode.log")
local cdir = require("compile-mode.dir")
local runner = require("compile-mode.runner")
local buffer = require("compile-mode.buffer")
local parser = require("compile-mode.parser")
local navigation = require("compile-mode.navigation")
local statusline = require("compile-mode.statusline")

local M = {}

-- Keep the established Lua API and ftplugin hooks on this facade.
M.level = errors.level
M.statusline_info = statusline.info
M.statusline = statusline.format
M.interrupt = runner.interrupt
M.close_buffer = buffer.close
M._parse_errors = parser.parse
M._follow_cursor = navigation.follow_cursor
M._gf = navigation.goto_file
M._CTRL_W_f = navigation.split_goto_file

M.first_error = navigation.first_error
M.current_error = navigation.current_error
M.next_error = navigation.next_error
M.prev_error = navigation.prev_error
M.goto_error = navigation.goto_error
M.debug_error = navigation.debug_error
M.next_error_follow = navigation.next_error_follow
M.move_to_next_error = navigation.move_to_next_error
M.move_to_next_file = navigation.move_to_next_file
M.move_to_prev_error = navigation.move_to_prev_error
M.move_to_prev_file = navigation.move_to_prev_file

---Prompt for (or get by parameter) a command and run it.
---
---@type fun(param: CommandParam?)
M.compile = a.void(
	---@param param CommandParam?
	function(param)
		local config = require("compile-mode.config.internal")

		log.debug("calling compile()")

		param = param or {}

		local command = param.args
		if not command or command == "" then
			local input_completion_func = "CompileInputComplete"
			if package.loaded["cmp_cmdline_prompt"] or config.input_word_completion then
				input_completion_func = "CompileInputCompleteWord"
			end

			local buf = vim.api.nvim_get_current_buf()
			local ft = vim.bo[buf].filetype
			---@type string
			local default_cmd = vim.g.compile_command
			if not default_cmd then
				if type(config.default_command) == "table" then
					default_cmd = config.default_command[ft] or config.default_command["*"] or ""
				elseif type(config.default_command) == "function" then
					default_cmd = config.default_command(ft) or ""
				else
					default_cmd = config.default_command or ""
				end
			end

			command = utils.input({
				prompt = "Compile command: ",
				default = default_cmd,
				completion = ("customlist,%s"):format(input_completion_func),
			})
		end

		if command == nil then
			return
		end

		vim.g.compile_command = command
		cdir.compilation_directory = vim.g.compilation_directory or vim.fn.getcwd()

		runner.run(command, param)
		vim.g.compilation_directory = nil
	end
)

---Rerun the last command.
---
---@type fun(param: CommandParam?)
M.recompile = a.void(
	---@param param CommandParam?
	function(param)
		local config = require("compile-mode.config.internal")

		log.debug("calling recompile()")

		param = param or {}

		if vim.g.compile_command then
			runner.run(vim.g.compile_command, param)
		elseif config.recompile_no_fail then
			M.compile(param)
		else
			vim.notify("Cannot recompile without previous command; compile first", vim.log.levels.ERROR)
		end
	end
)

---Load all compilation errors into the quickfix list, replacing the existing list.
---
---@type fun()
M.send_to_qflist = a.void(function()
	log.debug("calling send_to_qflist()")

	vim.api.nvim_exec_autocmds("QuickFixCmdPre", {})
	vim.fn.setqflist(errors.toqflist(errors.error_list), "r")
	vim.api.nvim_exec_autocmds("QuickFixCmdPost", {})
end)

---Load all compilation errors into the quickfix list, appending onto the existing list.
---
---@type fun()
M.add_to_qflist = a.void(function()
	log.debug("calling add_to_qflist()")

	vim.api.nvim_exec_autocmds("QuickFixCmdPre", {})
	vim.fn.setqflist(errors.toqflist(errors.error_list), "a")
	vim.api.nvim_exec_autocmds("QuickFixCmdPost", {})
end)

return M
