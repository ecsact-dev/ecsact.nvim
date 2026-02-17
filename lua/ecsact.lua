vim.filetype.add({ extension = { ecsact = "ecsact" } })

local function setup_tree_sitter()
	require("nvim-treesitter.parsers").ecsact = {
		install_info = {
			url = "https://github.com/ecsact-dev/tree-sitter-ecsact",
			branch = "main",
			files = { "src/parser.c" },
			generate_requires_npm = false,
			requires_generate_from_grammar = false,
			revision = nil,
		},
		tier = 0,
	}
end

if package.loaded["nvim-treesitter.parsers"] then
	setup_tree_sitter()
end

vim.api.nvim_create_autocmd("User", {
	pattern = "TSUpdate",
	callback = setup_tree_sitter,
})

vim.api.nvim_create_autocmd("FileType", {
	pattern = "ecsact",
	callback = function(args)
		pcall(vim.treesitter.start, args.buf)
	end,
})

return {
	-- for lazy.nvim
	setup = function() end,
}
