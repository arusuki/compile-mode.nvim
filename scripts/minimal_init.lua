-- No user config, plugin manager, network access, or dependency installation.
vim.opt.runtimepath:append(vim.fn.getcwd())
for name, env in pairs({ plenary = "PLENARY_PATH", baleia = "BALEIA_PATH" }) do
	local explicit = vim.env[env]
	if explicit then
		vim.opt.runtimepath:append(explicit)
	else
		for _, path in ipairs({
			"../" .. name .. ".nvim",
			vim.fn.stdpath("data") .. "/lazy/" .. name .. ".nvim",
			vim.fn.expand("~/.vim/plugged/" .. name .. ".nvim"),
		}) do
			vim.opt.runtimepath:append(path)
		end
	end
end
