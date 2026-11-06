-- A necessary literal for each built-in regex, not a replacement matcher.
-- Each token occurs outside optional branches (or in every alternative).
-- Snapshot by regex text so a user replacing a named matcher never inherits
-- a precondition that is invalid for their pattern. Unknown patterns run normally.
local literals = {
	absoft = ":",
	ada = " at ",
	aix = " in line ",
	ant = ":",
	bash = ": line ",
	borland = " ", -- Both Error and Warning prefixes end with a space.
	python_tracebacks_and_caml = ", line",
	cmake = "CMake ",
	cmake_info = ":",
	comma = ", line ",
	cucumber = ":",
	msft = "(",
	edg_1 = "(",
	edg_2 = ' of "',
	epc = " at (",
	ftnchek = "file ",
	gradle_kotlin = "(",
	iar = '",',
	ibm = "(",
	irix = ":",
	java = "(",
	jikes_file = ' compiling "',
	maven = ":[",
	clang_include = "In file included from ",
	gcc_include = "from ",
	["ruby_Test::Unit"] = ":in ",
	gmake = ": *** [",
	gnu = ":",
	lcc = "(",
	makepp = "makepp",
	mips_1 = ") in ",
	mips_2 = "(",
	omake = "*** omake: file ",
	oracle = " line ",
	perl = " line ",
	php = " on line ",
	rxp = " of file://",
	sun = "File = ",
	sun_ada = ", line ",
	watcom = "(",
	["4bsd"] = "(",
	["perl__Pod::Checker"] = " line ",
}

local by_regex = {}
for name, matcher in pairs(require("compile-mode.errors.matchers")) do
	by_regex[matcher.regex] = literals[name]
end
return by_regex
