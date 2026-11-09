## Introduction

`compile-mode.nvim` is a Neovim plugin which emulates the features of Emacs'
[Compilation
Mode](https://www.gnu.org/software/emacs/manual/html_node/emacs/Compilation-Mode.html).
It allows you to run commands which are output into a special buffer, and then
rerun that command over and over again as much as you need.

## Features

[Compile Mode Features](https://github.com/ej-shafran/compile-mode.nvim/assets/116496520/5541b9dd-70b7-4647-9c13-9e57813dac27)

## Input and process control

In a running compilation buffer, press `i` to edit a draft at the bottom. Use
normal Vim editing keys, then `Esc` and `:w` to send the whole draft to stdin.
The draft starts on a separate line below the read-only output, reusing the
empty trailing line when output ends with a newline. `Esc` pauses
editing without sending or discarding it; `i` resumes the same draft. The inline
hint follows the cursor within the draft and updates when entering or leaving
Insert mode.
Enter inserts a newline; an empty `:w` sends an empty answer. Submitted input
is recorded with a `> ` prefix. Output and submitted input remain read-only;
history editing and recall are not supported. `u` and `Ctrl-R` undo/redo draft
edits without undoing process output. In the history area, `Ctrl-R` recompiles.

Normal-mode `Ctrl-C` (or `:CompileInterrupt`) sends `SIGINT` and keeps collecting
output, including when the program handles the signal and continues running.
Insert-mode `Ctrl-C` keeps its Vim behavior. Other buffer-local controls are:

| Command | Action |
| --- | --- |
| `:CompileSignal USR1` | Send a signal by name, `SIG`-prefixed name, or number |
| `:CompileSignal STOP` / `CONT` | Suspend / resume the process group |
| `:CompileEOF` | Send EOF after submitting any draft |
| `:CompileStop` | Stop the job and immediately release the compilation session |

Lua equivalents are `require("compile-mode").signal("INT")`, `interrupt()`,
`send_eof()`, and `stop()`. The first three return `ok, error`; `stop()` retains
the previous `interrupt()` lifecycle, including `CompilationInterrupted`.
Signals now leave completion to the process exit callback (`CompilationFinished`).

Signals target the compilation job's Unix process group, including children in
that group. They do not track a job-control shell's changing foreground group;
Unix signals are unsupported on Windows. Commands use a PTY by default;
set `use_pseudo_terminal = false` to use pipes. EOF closes stdin with pipes;
with a PTY it sends `^D`,
which requires the usual terminal EOF configuration and does not permanently
close the channel. On Unix, PTY input echo is disabled before running the command,
matching Emacs; the `> ` record remains as the single copy of submitted input.
Set `pty_echo = true` to retain the terminal's default echo instead. Programs may
change their own echo settings, and their output is never removed by matching it
against submitted input. Echo setup requires `stty`; it does not apply to pipes or
Windows. This is a line-oriented buffer, not a terminal emulator or a
password-entry interface.

Failed sends and drafts left at process exit are preserved. Recompiling asks
before discarding a nonempty draft. Drafts use an independent edit journal;
native `:undo`/`:earlier` do not alter the transcript. Only unnamed `:w` submits
input; use `:Compile!` only for jobs that can complete without interactive input.

## Installation

Use your favorite plugin manager. `compile-mode.nvim` depends on
[plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

> [!WARNING]
>
> `compile-mode.nvim` only supports Neovim versions v0.10.0 and higher, and isn't expected to work for earlier versions.

Here's an example of a [Lazy](https://github.com/folke/lazy.nvim) config for
`compile-mode.nvim`:

```lua
return {
  "ej-shafran/compile-mode.nvim",
  version = "^5.0.0",
  -- you can just use the latest version:
  -- branch = "latest",
  -- or the most up-to-date updates:
  -- branch = "nightly",
  dependencies = {
    "nvim-lua/plenary.nvim",
    -- if you want to enable ANSI escape code support (colors && highlighting)
    -- in compilation output, add:
    -- { "m00qek/baleia.nvim", tag = "v1.3.0" },
  },
  config = function()
    ---@type CompileModeOpts
    vim.g.compile_mode = {
        -- if you use something like `nvim-cmp` or `blink.cmp` for completion,
        -- set this to fix tab completion in command mode:
        -- input_word_completion = true,

        -- to add ANSI escape code support (requires baleia.nvim):
        -- `baleia_options = {}` uses baleia's defaults, or pass a table to customize:
        -- ansi_color = { kind = "render", baleia_options = {} },

        -- to enable OSC sequence handling (titles, hyperlinks, notifications):
        -- built-in handlers for OSC 0/1/2/8/9 are injected when `kind` is "render";
        -- `handlers = {}` uses them, or pass a table to override:
        -- ansi_osc = { kind = "render", handlers = {} },

        -- to make `:Compile` replace special characters (e.g. `%`) in
        -- the command (and behave more like `:!`), add:
        -- bang_expansion = true,
    }
  end
}
```

## Default Configuration

Here is the full default configuration:

```lua
---@module "compile-mode"
---@type CompileModeOpts
vim.g.compile_mode = {
    -- The string to show in the compile prompt as a default.
    -- For an empty prompt, you can use:
    -- default_command = "",
    -- To use different defaults based on filetype, you can use a table:
    -- default_command = {
    --   python = "python %",
    --   lua = "lua %",
    --   javascript = "bun %",
    --   typescript = "bun %",
    --   c = "cc -o %:r % && ./%:r",
    --   cpp = "cc -std=c++23 -o %:r % && ./%:r",
    --   java = "javac % && java %:r",
    --   go = "go run %",
    -- },
    -- A function which returns the default command string is also supported:
    -- default_command = function()
    --   local filetype = vim.bo.filetype
    --   if filetype == "python" then
    --     return "python %"
    --   else
    --     return "make -k "
    --   end
    -- end,
    -- :h compile-mode.default_command
    default_command = "make -k ",
    -- Control how ANSI escape sequences are handled in compilation output.
    -- :h compile-mode.ansi_color
    ansi_color = {
        kind = "filter",
        -- Baleia options to pass to baleia.setup() when kind is "render".
        -- Use `{}` for baleia's defaults, or a table of baleia options.
        -- :h compile-mode.ansi_color
        baleia_options = {},
    },
    -- Expand commands, like `:!` (e.g. `:Compile echo %`)
    -- :h compile-mode.bang_expansion
    bang_expansion = false,
    -- Configure additional entering/leaving directory regexes.
    -- :h compile-mode.directory_change_matchers
    directory_change_matchers = {},
    -- Configure additional error regexes.
    -- :h compile-mode-errors
    error_regexp_table = {},
    -- List of filename regexes to ignore errors from.
    -- :h compile-mode.error_ignore_file_list
    error_ignore_file_list = {},
    -- The minimum error level to jump to.
    -- :h compile-mode.error_threshold
    error_threshold = require("compile-mode").level.WARNING,
    -- Automatically jump to the first error.
    -- :h compile-mode.auto_jump_to_first_error
    auto_jump_to_first_error = false,
    -- How long to highlight an error's location when jumping to it.
    -- :h compile-mode.error_locus_highlight
    error_locus_highlight = 500,
    -- Use Neovim diagnostics instead of opening the compilation buffer.
    -- :h compile-mode.use_diagnostics
    use_diagnostics = false,
    -- Default to calling `:Compile` for `:Recompile`
    -- when there's no previous command.
    -- :h compile-mode.recompile_no_fail
    recompile_no_fail = false,
    -- Ask to save unsaved buffers before compiling.
    -- :h compile-mode.ask_about_save
    ask_about_save = true,
    -- Ask to interrupt already running commands.
    -- :h compile-mode.ask_to_interrupt
    ask_to_interrupt = true,
    -- The name for the compilation buffer.
    -- :h compile-mode.buffer_name
    buffer_name = "*compilation*",
    -- The format for the time information
    -- at the top of the compilation buffer
    -- :h compile-mode.time_format
    time_format = "%a %b %e %H:%M:%S",
    -- Maximum number of lines allowed in the compilation buffer.
    -- :h compile-mode.max_lines
    max_lines = nil,

    -- Maximum bytes per parsed line (0 disables the limit). Full output stays visible.
    -- :h compile-mode.max_parse_line_length
    max_parse_line_length = 65536,
    -- List of regexes to hide from the output.
    -- :h compile-mode.hidden_output
    hidden_output = {},
    -- A table of environment variables to pass to commands.
    -- :h compile-mode.environment
    environment = nil,
    -- Clear all environment variables for each command.
    -- :h compile-mode.clear_environment
    clear_environment = false,
    -- Fix compilation for plugins like `nvim-cmp`.
    -- :h compile-mode.input_word_completion
    input_word_completion = false,
    -- Hide the compliation buffer.
    -- :h compile-mode.hidden_buffer
    hidden_buffer = false,
    -- Automatically focus the compilation buffer.
    -- :h compile-mode.focus_compilation_buffer
    focus_compilation_buffer = false,
    -- Automatically move the cursor to the end of the compilation buffer.
    -- :h compile-mode.auto_scroll
    auto_scroll = true,
    -- Jump back past the end/beginning of the errors
    -- with `:NextError`/`:PrevError`
    -- :h compile-mode.use_circular_error_navigation
    use_circular_error_navigation = false,
    -- Print debug information.
    -- :h compile-mode.debug
    debug = false,
    -- Use a pseudo terminal for command execution.
    -- :h compile-mode.use_pseudo_terminal
    use_pseudo_terminal = true,
    -- Retain terminal input echo for Unix PTY jobs (off by default, like Emacs).
    -- :h compile-mode.pty_echo
    pty_echo = false,
    -- Control how OSC sequences are handled (hyperlinks, titles, etc.)
    -- The default `handlers` is empty; when `kind` is `"render"`, built-in
    -- handlers for OSC 0/1/2/8/9 are injected automatically.
    -- :h compile-mode.ansi_osc
    ansi_osc = {
        kind = "render",
        handlers = {},
    }
}
```

## Custom Regexes

If you're looking for custom regexes for a specific programming language/tool, take a look at the Custom Regexes category in the GitHub Discussions tab - someone may have posted the regexes you're looking for. If you have a useful regex that hasn't been posted, go ahead and post it for other people to use!

## Contributing

Contributions are welcome in the form of GitHub issues and pull requests.

For contributing details see [CONTRIBUTING.md](CONTRIBUTING.md).

For implementation details, see the [architecture and performance guide](doc/architecture.md).
