local core = require("telescope-gtags.core")
local picker = require("telescope-gtags.picker")
local stack_view = require("telescope-gtags.stack_view")

local M = { job_running = false }

-- Re-export core functions for backward compatibility
M.exec_global = core.exec_global
M.exec_global_symbol = core.exec_global_symbol
M.exec_global_current_file = core.exec_global_current_file
M.global_definition = core.global_definition
M.global_reference = core.global_reference
M.updateGtags = core.updateGtags
M.setAutoIncUpdate = core.setAutoIncUpdate

function M.showDefinitionFromInput()
	local current_word = vim.fn.input("Enter definition target: ")
	if current_word == nil or current_word == "" then
		vim.notify("No input provided", vim.log.levels.WARN)
		return
	end
	local gtags_result = core.global_definition(current_word)
	picker.gtags_picker(gtags_result)
end

function M.showReferenceFromInput()
	local current_word = vim.fn.input({
		prompt = "Enter reference target: ",
		completion = "file",
		default = vim.fn.expand("<cword>"),
	})
	if current_word == nil or current_word == "" then
		vim.notify("No input provided", vim.log.levels.WARN)
		return
	end
	local gtags_result = core.global_reference(current_word)
	picker.gtags_picker(gtags_result)
end

function M.showDefinition()
	local current_word = vim.fn.expand("<cword>")
	if current_word == nil then
		return
	end
	local gtags_result = core.global_definition(current_word)
	picker.gtags_picker(gtags_result)
end

function M.showReference()
	local current_word = vim.fn.expand("<cword>")
	if current_word == nil then
		return
	end
	local gtags_result = core.global_reference(current_word)
	picker.gtags_picker(gtags_result)
end

function M.showCurrentFileTags()
	picker.gtags_picker(core.exec_global_current_file())
end

-- Stack View API
function M.stackViewDown(symbol)
	symbol = symbol or vim.fn.expand("<cword>")
	stack_view.open("down", symbol)
end

function M.stackViewToggle()
	stack_view.toggle_win()
end

--- Setup stack_view with options
---@param opts table
function M.setup(opts)
	opts = opts or {}
	if opts.stack_view then
		stack_view.setup(opts.stack_view)
	end
end

return M
