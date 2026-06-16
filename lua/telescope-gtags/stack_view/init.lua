local tree = require("telescope-gtags.stack_view.tree")
local hl = require("telescope-gtags.stack_view.hl")
local core = require("telescope-gtags.core")
local M = {}

M.opts = {
	tree_hl = true,
	size = "medium",
}

local size_presets = {
	medium = { width = 0.85, height = 0.7 },
	large = { width = 0.95, height = 0.95 },
}

-- Only "down" (callers) is supported via gtags global -r.
-- "up" (callees) is not natively supported by gtags.
M.dir_map = {
	down = {
		indicator = "<- ",
		query_func = function(symbol)
			return core.global_reference(symbol)
		end,
	},
}

M.cache = {
	sv = { buf = nil, win = nil },
	pv = { buf = nil, win = nil, files = {}, last_file = "" },
	last_win = nil,
	win_opened = false,
}

M.help = function()
	print([[
GtagsStackView commands:
open   : Open stack view window       (Usage: open down function)
         down : Show functions that call the queried function (callers)
toggle : Toggle stack view window     (Usage: toggle)
help   : Show this message            (Usage: help)
]])
end

M.ft = "GtagsStackView"
local api = vim.api
local fn = vim.fn
local root = nil
local buf_lines = nil
local cur_dir = nil
local buf_last_pos = nil

--- Check if a line looks like a function declaration/definition rather than a call.
--- A declaration has the symbol directly after type keywords (e.g. "int func(", "void *func(").
--- A call has the symbol after "=", "(", ",", etc. (e.g. "int ret = func(", "if (func(").
---@param line string the source line (trimmed)
---@param symbol string the symbol to check
---@return boolean true if it looks like a declaration
local function is_declaration_line(line, symbol)
	local trimmed = vim.trim(line)
	-- Pattern: type-keyword optional-* symbol (  — the symbol IS being declared
	local pattern = "^[%w_]+%s*%*%s*" .. vim.pesc(symbol) .. "%s*%("
	if string.match(trimmed, pattern) then
		return true
	end
	-- Pattern: type-keyword * symbol ;  — forward declaration without body
	local fwd_pattern = "^[%w_]+%s*%*%s*" .. vim.pesc(symbol) .. "%s*;"
	if string.match(trimmed, fwd_pattern) then
		return true
	end
	return false
end

--- Use tree-sitter to check if a symbol at given line in a file is a call site (not a declaration).
--- Falls back to regex-based detection if tree-sitter is unavailable.
---@param filename string
---@param lnum number 1-based line number
---@param symbol string the symbol to check
---@return boolean
local function is_call_site(filename, lnum, symbol)
	local abs_path = vim.fn.fnamemodify(filename, ":p")
	local line_str

	-- Try to read the actual line from a loaded buffer or file
	local bufnr = vim.fn.bufnr(abs_path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
		line_str = lines[1]
	else
		local ok, lines = pcall(vim.fn.readfile, abs_path)
		if ok and lines[lnum] then
			line_str = lines[lnum]
		end
	end

	if line_str then
		return not is_declaration_line(line_str, symbol)
	end

	return true -- can't read the line, keep the entry
end

--- Find the enclosing function name for a given line in a C file.
--- Searches backwards from lnum for a function definition pattern.
---@param filename string
---@param lnum number 1-based line number
---@return string|nil function name, or nil if not found
local function find_enclosing_function(filename, lnum)
	local abs_path = vim.fn.fnamemodify(filename, ":p")
	local lines

	local bufnr = vim.fn.bufnr(abs_path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		local ok, content = pcall(vim.fn.readfile, abs_path)
		if not ok then
			return nil
		end
		lines = content
	end

	-- Search backwards for a function definition:  type [*] name ( [params] ) {
	for i = lnum - 1, 1, -1 do
		local line = vim.trim(lines[i] or "")
		-- Match: return_type function_name(  (possibly with * for pointer return)
		local name = string.match(line, "^[%w_]+%s*%*?%s*([%w_]+)%s*%(")
		if name then
			-- Verify it's a definition (has { on this or next line), not a declaration
			local rest = lines[i] or ""
			local next_line = lines[i + 1] or ""
			if rest:find("{", 1, true) or next_line:find("{", 1, true) then
				return name
			end
		end
	end

	return nil
end

--- Convert a gtags result entry to a tree node.
--- Uses the enclosing function name as the node symbol.
--- gtags grep format: {path, line_nr, text, raw}
local function gtags_entry_to_node(entry)
	local func_name = find_enclosing_function(entry.path, entry.line_nr)
	if not func_name then
		-- Fallback: use first word from the gtags result text
		local trimmed = vim.trim(entry.text)
		func_name = string.match(trimmed, "^([%w_]+)") or trimmed
	end
	return tree.create_node(func_name, entry.path, entry.line_nr)
end

M.buf_lock = function(buf)
	api.nvim_set_option_value("readonly", true, { buf = buf })
	api.nvim_set_option_value("modifiable", false, { buf = buf })
end

M.buf_unlock = function(buf)
	api.nvim_set_option_value("readonly", false, { buf = buf })
	api.nvim_set_option_value("modifiable", true, { buf = buf })
end

M.pv_scroll = function(dir)
	local input = dir > 0 and [[]] or [[]]
	return function()
		vim.api.nvim_win_call(M.cache.pv.win, function()
			vim.cmd([[normal! ]] .. input)
		end)
	end
end

M.save_last_window = function()
	if M.cache.last_win ~= nil then
		return
	end
	M.cache.last_win = api.nvim_get_current_win()
end

M.set_keymaps = function()
	local opts = { buffer = M.cache.sv.buf, silent = true }

	vim.keymap.set("n", "q", M.toggle_win, opts)
	vim.keymap.set("n", "<esc>", M.toggle_win, opts)
	vim.keymap.set("n", "<tab>", M.toggle_children, opts)

	vim.keymap.set("n", "<cr>", function()
		M.open_action("none")
	end, opts)
	vim.keymap.set("n", "<C-v>", function()
		M.open_action("vert")
	end, opts)
	vim.keymap.set("n", "<C-s>", function()
		M.open_action("horiz")
	end, opts)

	vim.keymap.set("n", "<C-u>", M.pv_scroll(-1), opts)
	vim.keymap.set("n", "<C-y>", M.pv_scroll(-1), opts)
	vim.keymap.set("n", "<C-d>", M.pv_scroll(1), opts)
	vim.keymap.set("n", "<C-e>", M.pv_scroll(1), opts)
end

M.set_autocmds = function()
	local augroup = api.nvim_create_augroup("GtagsStackView", {})
	api.nvim_create_autocmd({ "BufLeave" }, {
		group = augroup,
		buffer = M.cache.sv.buf,
		callback = M.toggle_win,
	})

	api.nvim_create_autocmd("CursorMoved", {
		group = augroup,
		buffer = M.cache.sv.buf,
		callback = function()
			if M.opts.tree_hl then
				hl.refresh(M.cache.sv.buf, root)
			end
			M.preview_update()
		end,
	})

	api.nvim_create_autocmd("VimResized", {
		group = augroup,
		buffer = M.cache.sv.buf,
		callback = function()
			buf_last_pos = fn.line(".")
			M.buf_close()
			M.buf_open_and_update()
		end,
	})
end

M.buf_open = function()
	local vim_height = vim.o.lines
	local vim_width = vim.o.columns

	local preset = size_presets[M.opts.size]
	local width = math.floor(vim_width * preset.width * 0.5)
	local height = math.floor(vim_height * preset.height)
	local col = vim_width * (1 - preset.width) * 0.5
	local row = vim_height * (1 - preset.height) * 0.5

	M.save_last_window()

	M.cache.pv.buf = M.cache.pv.buf or api.nvim_create_buf(false, true)
	M.cache.pv.win = M.cache.pv.win
		or api.nvim_open_win(M.cache.pv.buf, true, {
			relative = "editor",
			title = "preview",
			title_pos = "center",
			width = width,
			height = height,
			col = col + width + 1,
			row = row,
			style = "minimal",
			focusable = false,
			border = "single",
		})
	api.nvim_set_option_value("filetype", "c", { buf = M.cache.pv.buf })
	api.nvim_set_option_value("cursorline", true, { win = M.cache.pv.win })

	M.cache.sv.buf = M.cache.sv.buf or api.nvim_create_buf(false, true)
	M.cache.sv.win = M.cache.sv.win
		or api.nvim_open_win(M.cache.sv.buf, true, {
			relative = "editor",
			title = M.ft,
			title_pos = "center",
			width = width,
			height = height,
			col = col - 1,
			row = row,
			style = "minimal",
			focusable = false,
			border = "single",
		})
	api.nvim_set_option_value("filetype", M.ft, { buf = M.cache.sv.buf })
	api.nvim_set_option_value("cursorline", true, { win = M.cache.sv.win })

	M.set_keymaps()
	M.set_autocmds()

	M.cache.win_opened = true
end

M.buf_close = function()
	if M.cache.sv.buf ~= nil and api.nvim_buf_is_valid(M.cache.sv.buf) then
		api.nvim_buf_delete(M.cache.sv.buf, { force = true })
	end

	if M.cache.sv.win ~= nil and api.nvim_win_is_valid(M.cache.sv.win) then
		api.nvim_win_close(M.cache.sv.win, true)
	end

	if M.cache.pv.buf ~= nil and api.nvim_buf_is_valid(M.cache.pv.buf) then
		api.nvim_buf_delete(M.cache.pv.buf, { force = true })
	end

	if M.cache.pv.win ~= nil and api.nvim_win_is_valid(M.cache.pv.win) then
		api.nvim_win_close(M.cache.pv.win, true)
	end

	if M.cache.last_win ~= nil and api.nvim_win_is_valid(M.cache.last_win) then
		api.nvim_set_current_win(M.cache.last_win)
	end

	M.cache.sv.buf = nil
	M.cache.sv.win = nil
	M.cache.pv.buf = nil
	M.cache.pv.win = nil
	M.cache.pv.last_file = ""
	M.cache.last_win = nil
	M.cache.win_opened = false
end

M.buf_open_and_update = function()
	if root == nil then
		return
	end

	if not M.cache.win_opened then
		M.buf_open()
	end

	buf_lines = {}
	M.buf_create_lines(root)

	M.buf_unlock(M.cache.sv.buf)
	api.nvim_buf_set_lines(M.cache.sv.buf, 0, -1, false, buf_lines)
	if buf_last_pos ~= nil then
		api.nvim_win_set_cursor(M.cache.sv.win, { buf_last_pos, 0 })
		buf_last_pos = nil
	end
	M.buf_lock(M.cache.sv.buf)
end

M.read_lines_from_file = function(file)
	local lines = {}
	for line in io.lines(file) do
		lines[#lines + 1] = line
	end
	return lines
end

M.preview_update = function()
	vim.schedule(function()
		local _, filename, lnum = M.line_to_data(fn.getline("."))
		if filename == "" then
			M.cache.pv.last_file = ""
			api.nvim_buf_set_lines(M.cache.pv.buf, 0, -1, false, {})
			return
		end
		if filename ~= M.cache.pv.last_file then
			local lines = M.cache.pv.files[filename] or M.read_lines_from_file(filename)
			M.cache.pv.files[filename] = lines
			M.cache.pv.last_file = filename
			api.nvim_buf_set_lines(M.cache.pv.buf, 0, -1, false, lines)
		end
		api.nvim_win_set_cursor(M.cache.pv.win, { lnum, 0 })
	end)
end

M.line_to_data = function(line)
	line = vim.trim(line)
	local line_split = vim.split(line, "%s+")
	local symbol = line_split[2]
	local filename = ""
	local lnum = 0

	if #line_split == 3 then
		local file_loc = vim.split(line_split[3], "::")
		filename = file_loc[1]:sub(2)
		lnum = tonumber(file_loc[2]:sub(1, -2), 10)
	end

	return symbol, filename, lnum
end

M.buf_create_lines = function(node)
	local item = ""
	if node.is_root then
		item = node.data.symbol
	else
		item = string.format(
			"%s%s%s [%s::%s]",
			string.rep(" ", node.depth * #M.dir_map[cur_dir].indicator),
			M.dir_map[cur_dir].indicator,
			node.data.symbol,
			node.data.filename,
			node.data.lnum
		)
	end

	table.insert(buf_lines, item)
	node.id = #buf_lines

	if not node.children then
		return
	end

	for _, c in ipairs(node.children) do
		M.buf_create_lines(c)
	end
end

M.toggle_children = function()
	if vim.bo.filetype ~= M.ft then
		return
	end

	if cur_dir == nil then
		return
	end

	if root == nil then
		return
	end

	local cur_line = fn.line(".")

	if cur_line == 1 then
		return
	end

	local psymbol, pfilename, plnum = M.line_to_data(fn.getline("."))
	local parent_id = cur_line
	local gtags_res = M.dir_map[cur_dir].query_func(psymbol)

	if not gtags_res or gtags_res.count == 0 then
		return
	end

	local children = {}
	for _, r in ipairs(gtags_res) do
		local node = gtags_entry_to_node(r)
		if is_call_site(node.data.filename, node.data.lnum, node.data.symbol) then
			table.insert(children, node)
		end
	end

	root = tree.update_node(root, parent_id, children)
	M.buf_open_and_update()
end

M.open = function(dir, symbol)
	if vim.bo.filetype == M.ft then
		return
	end

	M.buf_close()
	root = nil
	buf_last_pos = nil

	if not M.dir_map[dir] then
		vim.notify("GtagsStackView: unsupported direction '" .. dir .. "'. Only 'down' is supported.", vim.log.levels.WARN)
		return
	end

	local gtags_res = M.dir_map[dir].query_func(symbol)

	if not gtags_res or gtags_res.count == 0 then
		vim.notify("GtagsStackView: no results for '" .. symbol .. "'", vim.log.levels.WARN)
		return
	end

	cur_dir = dir

	local children = {}
	for _, r in ipairs(gtags_res) do
		local node = gtags_entry_to_node(r)
		if is_call_site(node.data.filename, node.data.lnum, node.data.symbol) then
			table.insert(children, node)
		end
	end

	root = tree.create_node(symbol, "", 0)
	root.children = children
	root.is_root = true

	M.buf_open_and_update()
end

M.toggle_win = function()
	if vim.bo.filetype == M.ft then
		buf_last_pos = fn.line(".")
		M.buf_close()
		return
	end
	M.buf_open_and_update()
end

M.open_action = function(split)
	if vim.bo.filetype ~= M.ft then
		return
	end

	if fn.line(".") == 1 then
		return
	end

	local _, pfilename, plnum = M.line_to_data(fn.getline("."))
	M.toggle_win()

	if split == "vert" then
		vim.cmd("vsplit")
	elseif split == "horiz" then
		vim.cmd("split")
	end

	if vim.fn.expand("%:p") == vim.fn.fnamemodify(pfilename, ":p") then
		vim.api.nvim_win_set_cursor(0, { plnum, 0 })
	else
		core.jump_to(pfilename, plnum)
	end
end

M.run_cmd = function(args)
	local cmd = args[1]

	local error_tail = "' is invalid, see :GtagsStackView help"
	local error_msg = "command '" .. (cmd or "") .. error_tail

	if not cmd then
		vim.notify(error_msg, vim.log.levels.WARN)
		return
	end

	if vim.startswith(cmd, "o") then
		local stk_dir = args[2]

		error_msg = "direction '" .. (stk_dir or "") .. error_tail

		if not stk_dir then
			vim.notify(error_msg, vim.log.levels.WARN)
			return
		end

		local symbol = args[3] or vim.fn.expand("<cword>")
		if vim.startswith(stk_dir, "d") then
			stk_dir = "down"
		else
			vim.notify(error_msg, vim.log.levels.WARN)
			return
		end
		M.open(stk_dir, symbol)
	elseif vim.startswith(cmd, "t") then
		M.toggle_win()
	elseif vim.startswith(cmd, "h") then
		M.help()
	else
		vim.notify(error_msg, vim.log.levels.WARN)
	end
end

M.set_user_cmd = function()
	vim.api.nvim_create_user_command("GtagsStackView", function(opts)
		M.run_cmd(opts.fargs)
	end, {
		nargs = "*",
		complete = function(_, line)
			local cmds = { "open", "toggle", "help" }
			local l = vim.split(line, "%s+")
			local n = #l - 2

			if n == 0 then
				return vim.tbl_filter(function(val)
					return vim.startswith(val, l[2])
				end, cmds)
			end

			if n == 1 and vim.startswith(l[2], "o") then
				return { "down" }
			end
		end,
	})
end

M.setup = function(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	if not size_presets[M.opts.size] then
		vim.notify(string.format('Invalid stack_view size "%s", using "medium"', M.opts.size), vim.log.levels.WARN)
		M.opts.size = "medium"
	end
	M.set_user_cmd()
end

return M
