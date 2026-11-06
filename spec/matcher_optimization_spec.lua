local helpers = require("spec.test_helpers")
local errors = require("compile-mode.errors")

-- Every builtin has a positive witness. A missing token must only reject a
-- nonmatch; the native regex remains authoritative for captures and severity.
local fixtures = {
	absoft = 'Error on line 12 of "main.f":',
	ada = "warning: bad at main.adb:12",
	aix = "compiler in line 12 of file main.c. ",
	ant = "[javac] Main.java:12: warning",
	bash = "script.sh: line 12: failure",
	borland = "Error E100 main.c 12: bad",
	python_tracebacks_and_caml = '  File "main.py", line 12',
	cmake = "CMake Warning at CMakeLists.txt:12 (add_executable):",
	cmake_info = "  CMakeLists.txt:12 (add_executable)",
	comma = '"main.c", line 12: warning: failure',
	cucumber = "cucumber features/main.feature:12",
	msft = "main.cpp(12) : warning C123: failure",
	edg_1 = "main.cpp(12): warning",
	edg_2 = 'instantiated at line 12 of "main.cpp"',
	epc = "Error 12 at (34:main.f)",
	ftnchek = "Warning bad line 12 col 3 file main.f",
	gradle_kotlin = "w: main.kt: (12, 3)",
	iar = '"main.c",12 ---Error[123]: failure',
	ibm = "main.c(12:3) : warning",
	irix = "cc: main.c, line 12: failure",
	java = "    at pkg.Main.run(Main.java:12)",
	jikes_file = 'Found 1 error compiling "Main.java":',
	maven = "[ERROR] Main.java:[12,3] failure",
	clang_include = "In file included from main.h:12:",
	gcc_include = "                 from main.h:12,",
	["ruby_Test::Unit"] = "    main.rb:12:in failure",
	gmake = "make: *** [Makefile:12: target]",
	gnu = "main.c:12:3: warning: failure",
	lcc = "W, main.c(12, 3",
	makepp = "makepp: warning: problem `m '",
	mips_1 = "error (12) in main.c",
	mips_2 = "error in main.c(12)",
	omake = "*** omake: file main.ml changed",
	oracle = "Error at line 12, column 3 in file main.pc:",
	perl = "failure at main.pl line 12.",
	php = "Fatal error: failure in main.php on line 12",
	rxp = "Error: failure\ncontext line 12 char 3 of file://main.xml",
	sun = "cc: WARNING File = main.f, Line = 12, Column = 3",
	sun_ada = "main.adb, line 12, char 3:",
	watcom = "main.c(12): Warning! W123: failure",
	["4bsd"] = "/src/main.c(12): warning:",
	["perl__Pod::Checker"] = "*** WARNING problem at line 12 in file main.pod",
}

describe("matcher candidate filtering", function()
	before_each(helpers.setup_tests)

	it("preserves captures for every built-in matcher", function()
		local builtins = require("compile-mode.errors.matchers")
		local config = require("compile-mode.config.internal")
		assert.are.equal(vim.tbl_count(builtins), vim.tbl_count(fixtures))
		for name, matcher in pairs(builtins) do
			local line = assert(fixtures[name], name)
			local native = vim.fn.matchlist(line, matcher.regex)
			assert.is_true(#native > 0, "invalid fixture for " .. name)
			config.error_regexp_table = { [name] = matcher }
			local parsed = assert(errors.parse(line, 7), name)
			assert.are.equal(name, parsed.group)
			assert.are.equal(native[matcher.filename + 1], parsed.filename.value, name)
			assert.are.equal(7, parsed.linenum)
		end
	end)

	it("does not apply a built-in name's precondition to a replacement regex", function()
		local config = require("compile-mode.config.internal")
		config.error_regexp_table = {
			gnu = { regex = [[^CUSTOM \(\S\+\) \([0-9]\+\)$]], filename = 1, row = 2 },
		}
		local parsed = assert(errors.parse("CUSTOM custom.c 12", 5))
		assert.are.equal("gnu", parsed.group)
		assert.are.equal("custom.c", parsed.filename.value)
		assert.are.equal(12, parsed.row.value)
	end)

	it("preserves priority and ignored-file fallback for custom matchers", function()
		local config = require("compile-mode.config.internal")
		config.error_regexp_table = {
			first = { regex = [[^\(ignored.c\) \(main.c\) \([0-9]\+\)$]], filename = 1, row = 3, priority = 2 },
			second = { regex = [[^\(ignored.c\) \(main.c\) \([0-9]\+\)$]], filename = 2, row = 3, priority = 1 },
		}
		local parsed = assert(errors.parse("ignored.c main.c 12", 1))
		assert.are.equal("first", parsed.group)
		config.error_ignore_file_list = { [[^ignored\.c$]] }
		parsed = assert(errors.parse("ignored.c main.c 12", 1))
		assert.are.equal("second", parsed.group)
		assert.are.equal("main.c", parsed.filename.value)
	end)

	it("uses every format in a mixed-language stream", function()
		local expected = { "gnu", "python_tracebacks_and_caml", "cmake", "maven", "gnu" }
		for i, name in ipairs(expected) do
			local parsed = assert(errors.parse(fixtures[name], i))
			assert.are.equal(name, parsed.group)
		end
	end)

	it("reloads the ordered candidates when configuration is reloaded", function()
		assert(errors.parse(fixtures.gnu, 1))
		helpers.setup_tests({
			error_regexp_table = {
				custom = { regex = [[^NEW \(\S\+\)$]], filename = 1, priority = 10 },
			},
		})
		local parsed = assert(errors.parse("NEW custom.c", 1))
		assert.are.equal("custom", parsed.group)
	end)

	it("keeps command prefix capture positions", function()
		local utils = require("compile-mode.utils")
		assert.are.same({}, utils.match_command_ouput("build step 12 complete", 7))
		assert.are.same({
			{ "CompileModeCommandOutput", 7, { start = 1, end_ = 9 } },
			{ "CompileModeMessageRow", 7, { start = 6, end_ = 7 } },
		}, utils.match_command_ouput("make[12]: building", 7))
	end)
end)
