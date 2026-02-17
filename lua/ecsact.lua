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

local lsp_is_starting = false
local function ensure_ecsact_lsp_started()
	local current_buf = vim.api.nvim_get_current_buf()

	if lsp_is_starting then
		return
	end

	local clients = vim.lsp.get_clients({ name = "ecsact" })
	if #clients > 0 then
		-- Check if any of the existing clients cover the current buffer
		for _, client in ipairs(clients) do
			if vim.lsp.buf_is_attached(current_buf, client.id) then
				return
			end
		end
	end

	local bazel_root = vim.fs.root(vim.fn.getcwd(), { "MODULE.bazel" })
	if not bazel_root then
		return
	end

	lsp_is_starting = true
	local cache_dir = vim.fn.stdpath("cache") .. "/ecsact-lsp"
	vim.fn.mkdir(cache_dir, "p")
	local lsp_exe_path = cache_dir .. "/ecsact_lsp_server"
	if vim.fn.has("win32") == 1 then
		lsp_exe_path = lsp_exe_path .. ".exe"
	end

	local function start_lsp(exe_path)
		lsp_is_starting = false
		vim.lsp.start({
			name = "ecsact",
			root_dir = bazel_root,
			cmd = { exe_path, "--stdio" },
			trace = "verbose",
		}, { bufnr = current_buf })
	end

	local function run_bazel(args, callback)
		local stdout = vim.uv.new_pipe()
		local stderr = vim.uv.new_pipe()
		local stdout_data = {}
		local stderr_data = {}

		local handle
		handle = vim.uv.spawn("bazel", {
			args = args,
			cwd = bazel_root,
			stdio = { nil, stdout, stderr },
		}, function(code, signal)
			if handle then
				handle:close()
			end
			stdout:close()
			stderr:close()
			vim.schedule(function()
				callback(code, table.concat(stdout_data), table.concat(stderr_data))
			end)
		end)

		if not handle then
			lsp_is_starting = false
			vim.notify("ecsact.nvim: Failed to spawn bazel", vim.log.levels.ERROR)
			return
		end

		vim.uv.read_start(stdout, function(err, data)
			if data then
				table.insert(stdout_data, data)
			end
		end)
		vim.uv.read_start(stderr, function(err, data)
			if data then
				table.insert(stderr_data, data)
			end
		end)
	end

	-- Build the LSP server
	run_bazel({ "build", "@ecsact//ecsact_lsp_server" }, function(code, stdout, stderr)
		if code ~= 0 then
			lsp_is_starting = false
			vim.notify("ecsact.nvim: bazel build failed\n" .. stderr, vim.log.levels.ERROR)
			return
		end

		-- Query the output file path
		run_bazel({ "cquery", "@ecsact//ecsact_lsp_server", "--output=files" }, function(q_code, q_stdout, q_stderr)
			if q_code ~= 0 then
				lsp_is_starting = false
				vim.notify("ecsact.nvim: bazel cquery failed\n" .. q_stderr, vim.log.levels.ERROR)
				return
			end

			local relative_path = vim.trim(q_stdout):gsub("\r", "")
			if relative_path == "" then
				lsp_is_starting = false
				vim.notify("ecsact.nvim: Could not resolve LSP path from bazel", vim.log.levels.ERROR)
				return
			end

			local full_path = bazel_root .. "/" .. relative_path
			-- Copy to cache for stability
			vim.uv.fs_copyfile(full_path, lsp_exe_path, { excl = false }, function(err)
				vim.schedule(function()
					if err then
						-- If we can't copy, it might be because it's running.
						-- Use existing cached exe if possible, otherwise fallback to full path.
						if vim.fn.filereadable(lsp_exe_path) == 1 then
							start_lsp(lsp_exe_path)
						else
							start_lsp(full_path)
						end
					else
						-- Ensure executable (on non-windows)
						if vim.fn.has("win32") == 0 then
							vim.uv.fs_chmod(lsp_exe_path, 493) -- 0755
						end
						start_lsp(lsp_exe_path)
					end
				end)
			end)
		end)
	end)
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
		vim.bo[args.buf].commentstring = "// %s"
		vim.bo[args.buf].comments = "s1:/*,mb:*,ex:*/,://"
		pcall(vim.treesitter.start, args.buf)
		ensure_ecsact_lsp_started()
	end,
})

return {
	-- for lazy.nvim
	setup = function() end,
}
