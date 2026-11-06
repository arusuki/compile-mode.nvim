-- Focused acceptance workloads for the remaining output and metadata hotspots.
local s = require("scripts.support")
local samples = tonumber(vim.env.BENCH_SAMPLES) or 5
local cases = {}

local function register(name, operation)
	cases[name] = function()
		local result = operation()
		result.name = name
		result.passed = true
		return result
	end
end

for _, count in ipairs({ 1000, 2000, 4000 }) do
	register("output/carriage_returns/" .. count, function()
		s.setup()
		local output = require("compile-mode.output")
		local chunk = { string.rep("x", 255) .. "\r" }
		return s.measure("fragmented progress", count, function()
			return {}
		end, function()
			local tail, displayed = "", nil
			for _ = 1, count do
				displayed, tail = output.normalize(chunk, tail, {})
			end
			return displayed
		end, function(_, displayed)
			s.equal({ string.rep("x", 255) }, displayed)
		end, samples)
	end)

	register("ansi/hyperlinks/" .. count, function()
		s.setup({ ansi_osc = { kind = "render" } })
		local ansi = require("compile-mode.ansi")
		local text = string.rep("\27]8;;https://example.test\7x\27]8;;\7", count)
		return s.measure("OSC hyperlinks", count, function()
			ansi.reset()
			return { buf = s.buffer({ "" }) }
		end, function(ctx)
			ansi.buf_set_lines(ctx.buf, 0, -1, { text })
			s.drain()
		end, function(ctx)
			s.equal({ string.rep("x", count) }, vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
			s.equal(count, #vim.api.nvim_buf_get_extmarks(ctx.buf, ansi.ns_id, 0, -1, {}))
		end, samples)
	end)
end

register("parser/one_mib_colon", function()
	s.setup()
	local parser = require("compile-mode.parser")
	local text = string.rep("x", 1024 * 1024 - 1) .. ":"
	return s.measure("oversized line scan", #text, function()
		require("compile-mode.state").reset()
		return { buf = s.buffer({ text }) }
	end, function(ctx)
		return parser.scan(ctx.buf, 0, -1)
	end, function(ctx)
		s.equal({}, require("compile-mode.errors").error_list)
		s.equal({ text }, vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
	end, samples)
end)

for _, transitions in ipairs({ 0, 10000 }) do
	for _, kind in ipairs({ "quickfix", "diagnostics", "diagnostics_repeat" }) do
		register("metadata/" .. kind .. "/" .. transitions .. "_transitions", function()
			s.setup()
			local errors = require("compile-mode.errors")
			local dir = require("compile-mode.dir")
			local target = vim.fn.bufadd("/tmp/compile-mode-hotspot-source/file.c")
			local fixture = {}
			for i = 1, 10000 do
				fixture[2 * i] = assert(errors.parse("file.c:1:1: error: failure", 2 * i))
			end
			return s.measure(kind, kind == "diagnostics_repeat" and 3 or 1, function()
				require("compile-mode.state").reset()
				dir.compilation_directory = "/tmp/compile-mode-hotspot-source"
				for i = 1, transitions do
					dir.dir_changes[2 * i - 1] = "/tmp/compile-mode-hotspot-source"
				end
				errors.error_list = fixture
				return {}
			end, function()
				if kind == "quickfix" then
					return errors.toqflist(errors.error_list)
				end
				local result
				for _ = 1, kind == "diagnostics_repeat" and 3 or 1 do
					if kind == "diagnostics_repeat" and errors.diagnostics_for_buffer then
						result = errors.diagnostics_for_buffer(target)
					else
						result = errors.todiagnostic(target, errors.error_list)
					end
				end
				return result
			end, function(_, result)
				s.equal(10000, #result)
			end, samples)
		end)
	end
end

local name = arg[1]
if name == "list" then
	s.finish(vim.tbl_keys(cases))
else
	local ok, result = pcall(assert(cases[name], "unknown case: " .. tostring(name)))
	s.finish(ok and result or { name = name, passed = false, error = tostring(result) })
end
