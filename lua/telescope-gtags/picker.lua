local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M = {}

--- Open telescope picker with gtags results
---@param gtags_result table with .count and array entries {path, line_nr, text, raw}
function M.gtags_picker(gtags_result)
	if gtags_result.count == 0 then
		vim.notify("gtags: no results found", vim.log.levels.WARN)
		return
	end

	if gtags_result.count == 1 then
		vim.fn.settagstack(vim.fn.win_getid(), {
			items = { { tagname = vim.fn.expand("<cword>"), from = vim.fn.getpos(".") } },
		}, "a")
		vim.api.nvim_command(string.format(":edit +%d %s", gtags_result[1].line_nr, gtags_result[1].path))
		return
	end

	local opts = {}
	pickers.new(opts, {
		prompt_title = "GNU Gtags",
		finder = finders.new_table({
			results = gtags_result,
			entry_maker = function(entry)
				local absolute_path = vim.fn.fnamemodify(entry.path, ":p")
				return {
					value = entry.raw,
					ordinal = entry.raw,
					display = entry.raw,
					filename = absolute_path,
					path = absolute_path,
					lnum = entry.line_nr,
					start = entry.line_nr,
					col = 1,
				}
			end,
		}),
		previewer = conf.grep_previewer(opts),
		sorter = conf.generic_sorter(opts),
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace(function()
				actions.close(prompt_bufnr)
				local selection = action_state.get_selected_entry()
				vim.fn.settagstack(vim.fn.win_getid(), {
					items = { { tagname = vim.fn.expand("<cword>"), from = vim.fn.getpos(".") } },
				}, "a")
				vim.api.nvim_command(string.format(":edit +%d %s", selection.lnum, selection.filename))
			end)
			return true
		end,
	}):find()
end

return M
