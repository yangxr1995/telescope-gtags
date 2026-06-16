-- telescope-gtags core: gtags query execution and result parsing
local M = { job_running = false }

--- Execute a raw global command and parse grep-format results
---@param global_cmd string
---@return table results with .count and array entries {path, line_nr, text, raw}
function M.exec_global(global_cmd)
	local result = {}
	local f = io.popen(global_cmd)

	result.count = 0
	repeat
		local line = f:read("*l")
		if line then
			local path, line_nr, text = string.match(line, "(.*):(%d+):(.*)")
			if path and line_nr then
				table.insert(result, {
					path = path,
					line_nr = tonumber(line_nr),
					text = text,
					raw = line,
				})
				result.count = result.count + 1
			end
		end
	until line == nil

	f:close()
	return result
end

--- Execute a global command for a specific symbol
---@param symbol string
---@param extras string additional flags (e.g. "-d", "-r")
---@return table
function M.exec_global_symbol(symbol, extras)
	local global_cmd = string.format('global --result="grep" %s "%s" 2>&1', extras, symbol)
	return M.exec_global(global_cmd)
end

--- Get all tags in the current file
---@return table
function M.exec_global_current_file()
	local file = vim.fn.expand("%")
	local global_cmd = string.format('global --result="grep" -f "%s" 2>&1', file)
	return M.exec_global(global_cmd)
end

--- Get definitions of a symbol
---@param symbol string
---@return table
function M.global_definition(symbol)
	return M.exec_global_symbol(symbol, "-d")
end

--- Get references of a symbol
---@param symbol string
---@return table
function M.global_reference(symbol)
	return M.exec_global_symbol(symbol, "-r")
end

--- Internal: run global -u asynchronously
local function global_update()
	local job_handle, pid = vim.loop.spawn("global", {
		args = { "-u" },
	}, function(code, signal)
		if code ~= 0 then
			print("ERROR: global -u return errors")
		end
		M.job_running = false
		job_handle:close()
	end)
end

--- Update gtags database asynchronously
function M.updateGtags()
	local handle = vim.loop.spawn("global", {
		args = { "--print", "dbpath" },
	}, function(code, signal)
		if code == 0 and M.job_running == false then
			M.job_running = true
			global_update()
		end
		handle:close()
	end)
end

--- Enable/disable automatic gtags update on file save
---@param enable boolean
function M.setAutoIncUpdate(enable)
	if enable then
		vim.api.nvim_command("augroup AutoUpdateGtags")
		vim.api.nvim_command('autocmd BufWritePost * lua require("telescope-gtags").updateGtags()')
		vim.api.nvim_command("augroup END")
	end
end

return M
