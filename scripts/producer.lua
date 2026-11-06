-- A bounded producer used by tests and benchmarks, independent of shell utilities.
local mode = arg[1]
local count = tonumber(arg[2]) or 100
if mode == "stream" then
	for i = 1, count do
		io.write("line " .. i .. "\n")
	end
	io.flush()
	-- Acknowledged by a marker so assertions can run before completion.
	io.write("READY\n")
	io.flush()
	vim.uv.sleep(1200)
elseif mode == "nul" then
	io.write("out\0put\n")
	io.flush()
	vim.uv.sleep(50)
	io.stderr:write("err\0or\n")
	io.stderr:flush()
elseif mode == "mixed" then
	io.stderr:write("\27[32mcompiler\27[0m\n")
	io.stderr:flush()
	vim.uv.sleep(50)
	io.write("program\n")
	io.flush()
else
	for i = 1, count do
		if mode == "errors" then
			io.write(("file.c:%d:1: error: failure\n"):format(i))
		elseif mode == "ansi" then
			io.write(("\27[32mbuild %d\27[0m\27[K\n"):format(i))
		else
			io.write(("build step %d complete\n"):format(i))
		end
	end
	io.flush()
end
