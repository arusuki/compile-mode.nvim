local level = require("compile-mode.constants").level

---This mirrors the `error_regexp_alist` variable from Emacs.
---See `error_regexp_table` in the README to understand this more in depth.
---
---@type table<string, CompileModeRegexpMatcher>
local matchers = {
	absoft = {
		regex = '^\\%([Ee]rror on \\|[Ww]arning on\\( \\)\\)\\?[Ll]ine[ \t]\\+\\([0-9]\\+\\)[ \t]\\+of[ \t]\\+"\\?\\([a-zA-Z]\\?:\\?[^":\n]\\+\\)"\\?:',
		filename = 3,
		row = 2,
		type = { 1 },
	},
	ada = {
		regex = "\\(warning: .*\\)\\? at \\([^ \n]\\+\\):\\([0-9]\\+\\)$",
		filename = 2,
		row = 3,
		type = { 1 },
	},
	aix = {
		regex = " in line \\([0-9]\\+\\) of file \\([^ \n]\\+[^. \n]\\)\\.\\? ",
		filename = 2,
		row = 1,
	},
	ant = {
		regex = "^[ \t]*\\%(\\[[^] \n]\\+\\][ \t]*\\)\\{1,2\\}\\(\\%([A-Za-z]:\\)\\?[^: \n]\\+\\):\\([0-9]\\+\\):\\%(\\([0-9]\\+\\):\\([0-9]\\+\\):\\([0-9]\\+\\):\\)\\?\\( warning\\)\\?",
		filename = 1,
		row = { 2, 4 },
		col = { 3, 5 },
		type = { 6 },
	},
	bash = {
		regex = "^\\([^: \n\t]\\+\\): line \\([0-9]\\+\\):",
		filename = 1,
		row = 2,
	},
	borland = {
		regex = "^\\%(Error\\|Warnin\\(g\\)\\) \\%([FEW][0-9]\\+ \\)\\?\\([a-zA-Z]\\?:\\?[^:( \t\n]\\+\\) \\([0-9]\\+\\)\\%([) \t]\\|:[^0-9\n]\\)",
		filename = 2,
		row = 3,
		type = { 1 },
	},
	python_tracebacks_and_caml = {
		regex = '^[ \t]*File \\("\\?\\)\\([^," \n\t<>]\\+\\)\\1, lines\\? \\([0-9]\\+\\)-\\?\\([0-9]\\+\\)\\?\\%($\\|,\\%( characters\\? \\([0-9]\\+\\)-\\?\\([0-9]\\+\\)\\?:\\)\\?\\([ \n]Warning\\%( [0-9]\\+\\)\\?:\\)\\?\\)',
		filename = 2,
		row = { 3, 4 },
		col = { 5, 6 },
		type = { 7 },
	},
	cmake = {
		regex = "^CMake \\%(Error\\|\\(Warning\\)\\) at \\(.*\\):\\([1-9][0-9]*\\) ([^)]\\+):$",
		filename = 2,
		row = 3,
		type = { 1 },
	},
	cmake_info = {
		regex = "^  \\%( \\*\\)\\?\\(.*\\):\\([1-9][0-9]*\\) ([^)]\\+)$",
		filename = 1,
		row = 2,
		type = level.INFO,
	},
	comma = {
		regex = '^"\\([^," \n\t]\\+\\)", line \\([0-9]\\+\\)\\%([(. pos]\\+\\([0-9]\\+\\))\\?\\)\\?[:.,; (-]\\( warning:\\|[-0-9 ]*(W)\\)\\?',
		filename = 1,
		row = 2,
		col = 3,
		type = { 4 },
	},
	cucumber = {
		regex = "\\%(^cucumber\\%( -p [^[:space:]]\\+\\)\\?\\|#\\)\\%( \\)\\([^(].*\\):\\([1-9][0-9]*\\)",
		filename = 1,
		row = 2,
	},
	msft = {
		regex = "^ *\\([0-9]\\+>\\)\\?\\(\\%([a-zA-Z]:\\)\\?[^ :(\t\n][^:(\t\n]*\\)(\\([0-9]\\+\\)) \\?: \\%(see declaration\\|\\%(warnin\\(g\\)\\|[a-z ]\\+\\) C[0-9]\\+:\\)",
		filename = 2,
		row = 3,
		type = { 4 },
	},
	edg_1 = {
		regex = "^\\([^ \n]\\+\\)(\\([0-9]\\+\\)): \\%(error\\|warnin\\(g\\)\\|remar\\(k\\)\\)",
		filename = 1,
		row = 2,
		type = { 3, 4 },
	},
	edg_2 = {
		regex = 'at line \\([0-9]\\+\\) of "\\([^ \n]\\+\\)"$',
		filename = 2,
		row = 1,
		type = level.INFO,
	},
	epc = {
		regex = "^Error [0-9]\\+ at (\\([0-9]\\+\\):\\([^)\n]\\+\\))",
		filename = 2,
		row = 1,
	},
	ftnchek = {
		regex = "\\(^Warning .*\\)\\? line[ \n]\\([0-9]\\+\\)[ \n]\\%(col \\([0-9]\\+\\)[ \n]\\)\\?file \\([^ :;\n]\\+\\)",
		filename = 4,
		row = 2,
		col = 3,
		type = { 1 },
	},
	gradle_kotlin = {
		regex = "^\\%(\\(w\\)\\|.\\): *\\(\\%([A-Za-z]:\\)\\?[^:\n]\\+\\): *(\\([0-9]\\+\\), *\\([0-9]\\+\\))",
		filename = 2,
		row = 3,
		col = 4,
		type = { 1 },
	},
	iar = {
		regex = '^"\\(.*\\)",\\([0-9]\\+\\)\\s-\\+\\%(Error\\|Warnin\\(g\\)\\)\\[[0-9]\\+\\]:',
		filename = 1,
		row = 2,
		type = { 3 },
	},
	ibm = {
		regex = "^\\([^( \n\t]\\+\\)(\\([0-9]\\+\\):\\([0-9]\\+\\)) : \\%(warnin\\(g\\)\\|informationa\\(l\\)\\)\\?",
		filename = 1,
		row = 2,
		col = 3,
		type = { 4, 5 },
	},
	irix = {
		regex = '^[-[:alnum:]_/ ]\\+: \\%(\\%([sS]evere\\|[eE]rror\\|[wW]arnin\\(g\\)\\|[iI]nf\\(o\\)\\)[0-9 ]*: \\)\\?\\([^," \n\t]\\+\\)\\%(, line\\|:\\) \\([0-9]\\+\\):',
		filename = 3,
		row = 4,
		type = { 1, 2 },
	},
	java = {
		regex = "^\\%([ \t]\\+at \\|==[0-9]\\+== \\+\\%(at\\|b\\(y\\)\\)\\).\\+(\\([^()\n]\\+\\):\\([0-9]\\+\\))$",
		filename = 2,
		row = 3,
		type = { 1 },
	},
	jikes_file = {
		regex = '^\\%(Found\\|Issued\\) .* compiling "\\(.\\+\\)":$',
		filename = 1,
		type = level.INFO,
	},
	maven = {
		regex = "^\\%(\\[\\%(ERROR\\|\\(WARNING\\)\\|\\(INFO\\)\\)] \\)\\?\\([^\n []\\%([^\n :]\\| [^\n/-]\\|:[^\n []\\)*\\):\\[\\([[:digit:]]\\+\\),\\([[:digit:]]\\+\\)] ",
		filename = 3,
		row = 4,
		col = 5,
		type = { 1, 2 },
	},
	clang_include = {
		regex = "^In file included from \\([^\n:]\\+\\):\\([0-9]\\+\\):$",
		filename = 1,
		row = 2,
		type = level.INFO,
		priority = 2,
	},
	gcc_include = {
		regex = "^\\%(In file included \\|                 \\|\t\\)from \\([0-9]*[^0-9\n]\\%([^\n :]\\| [^-/\n]\\|:[^ \n]\\)\\{-}\\):\\([0-9]\\+\\)\\%(:\\([0-9]\\+\\)\\)\\?\\%(\\(:\\)\\|\\(,\\|$\\)\\)\\?",
		filename = 1,
		row = 2,
		col = 3,
		type = { 4, 5 },
	},
	["ruby_Test::Unit"] = {
		regex = "^    [[ ]\\?\\([^ (].*\\):\\([1-9][0-9]*\\)\\(\\]\\)\\?:in ",
		filename = 1,
		row = 2,
	},
	gmake = {
		regex = ": \\*\\*\\* \\[\\%(\\(.\\{-1,}\\):\\([0-9]\\+\\): .\\+\\)\\]",
		filename = 1,
		row = 2,
		type = level.INFO,
	},
	gnu = {
		regex = "^\\%([[:alpha:]][-[:alnum:].]\\+: \\?\\|[ \t]\\%(in \\| from\\)\\)\\?\\(\\%([0-9]*[^0-9\\n]\\)\\%([^\\n :]\\| [^-/\\n]\\|:[^ \\n]\\)\\{-}\\)\\%(: \\?\\)\\([0-9]\\+\\)\\%(-\\([0-9]\\+\\)\\%(\\.\\([0-9]\\+\\)\\)\\?\\|[.:]\\([0-9]\\+\\)\\%(-\\%(\\([0-9]\\+\\)\\.\\)\\([0-9]\\+\\)\\)\\?\\)\\?:\\%( *\\(\\%(FutureWarning\\|RuntimeWarning\\|W\\%(arning\\)\\|warning\\)\\)\\| *\\([Ii]nfo\\%(\\>\\|formationa\\?l\\?\\)\\|I:\\|\\[ skipping .\\+ ]\\|instantiated from\\|required from\\|[Nn]ote\\)\\| *\\%([Ee]rror\\)\\|\\%([0-9]\\?\\)\\%([^0-9\\n]\\|$\\)\\|[0-9][0-9][0-9]\\)",
		filename = 1,
		row = { 2, 3 },
		col = { 5, 4 },
		type = { 8, 9 },
	},
	lcc = {
		regex = "^\\%(E\\|\\(W\\)\\), \\([^(\n]\\+\\)(\\([0-9]\\+\\),[ \t]*\\([0-9]\\+\\)",
		filename = 2,
		row = 3,
		col = 4,
		type = { 1 },
	},
	makepp = {
		regex = "^makepp\\%(\\%(: warning\\(:\\).\\{-}\\|\\(: Scanning\\|: [LR]e\\?l\\?oading makefile\\|: Imported\\|log:.\\{-}\\) \\|: .\\{-}\\)`\\(\\(\\S \\{-1,}\\)\\%(:\\([0-9]\\+\\)\\)\\?\\)['(]\\)",
		filename = 4,
		row = 5,
		type = { 1, 2 },
	},
	mips_1 = {
		regex = " (\\([0-9]\\+\\)) in \\([^ \n]\\+\\)",
		filename = 2,
		row = 1,
	},
	mips_2 = {
		regex = " in \\([^()\n ]\\+\\)(\\([0-9]\\+\\))$",
		filename = 1,
		row = 2,
	},
	omake = {
		regex = "^\\*\\*\\* omake: file \\(.*\\) changed",
		filename = 1,
	},
	oracle = {
		regex = "^\\%(Semantic error\\|Error\\|PCC-[0-9]\\+:\\).* line \\([0-9]\\+\\)\\%(\\%(,\\| at\\)\\? column \\([0-9]\\+\\)\\)\\?\\%(,\\| in\\| of\\)\\? file \\(.\\{-}\\):\\?$",
		filename = 3,
		row = 1,
		col = 2,
	},
	perl = {
		regex = " at \\([^ \n]\\+\\) line \\([0-9]\\+\\)\\%([,.]\\|$\\| during global destruction\\.$\\)",
		filename = 1,
		row = 2,
	},
	php = {
		regex = "\\%(Parse\\|Fatal\\) error: \\(.*\\) in \\(.*\\) on line \\([0-9]\\+\\)",
		filename = 2,
		row = 3,
	},
	-- TODO: support multi-line errors
	rxp = {
		regex = "^\\%(Error\\|Warnin\\(g\\)\\):.*\n.* line \\([0-9]\\+\\) char \\([0-9]\\+\\) of file://\\(.\\+\\)",
		filename = 4,
		row = 2,
		col = 3,
		type = { 1 },
	},
	sun = {
		regex = ": \\%(ERROR\\|WARNIN\\(G\\)\\|REMAR\\(K\\)\\) \\%([[:alnum:] ]\\+, \\)\\?File = \\(.\\+\\), Line = \\([0-9]\\+\\)\\%(, Column = \\([0-9]\\+\\)\\)\\?",
		filename = 3,
		row = 4,
		col = 5,
		type = { 1, 2 },
	},
	sun_ada = {
		regex = "^\\([^, \n\t]\\+\\), line \\([0-9]\\+\\), char \\([0-9]\\+\\)[:., (-]",
		filename = 1,
		row = 2,
		col = 3,
	},
	watcom = {
		regex = "^[ \t]*\\(\\%([a-zA-Z]:\\)\\?[^ :(\t\n][^:(\t\n]*\\)(\\([0-9]\\+\\)): \\?\\%(\\(Error! E[0-9]\\+\\)\\|\\(Warning! W[0-9]\\+\\)\\):",
		filename = 1,
		row = 2,
		type = { 4 },
	},
	["4bsd"] = {
		regex = "\\%(^\\|::  \\|\\S ( \\)\\(/[^ \n\t()]\\+\\)(\\([0-9]\\+\\))\\%(: \\(warning:\\)\\?\\|$\\| ),\\)",
		filename = 1,
		row = 2,
		type = { 3 },
	},
	["perl__Pod::Checker"] = {
		regex = "^\\*\\*\\* \\%(ERROR\\|\\(WARNING\\)\\).* \\%(at\\|on\\) line \\([0-9]\\+\\) \\%(.* \\)\\?in file \\([^ \t\n]\\+\\)",
		filename = 3,
		row = 2,
		type = { 1 },
	},
}

return matchers
