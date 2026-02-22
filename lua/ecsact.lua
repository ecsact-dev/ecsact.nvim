vim.filetype.add({ extension = { ecsact = "ecsact" } })

--- @class ecsact.lsp.EcsactSymbolParams
--- @field textDocument lsp.TextDocumentIdentifier
--- @field position lsp.Position

--- @class ecsact.lsp.EcsactCppSymbolResult
--- @field type string
--- @field implementation string

--- @class ecsact.lsp.EcsactSymbolResult
--- @field c string
--- @field cpp ecsact.lsp.EcsactCppSymbolResult
--- @field csharp string
--- @field rust string

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

local function get_ecsact_lsp_path()
	local cache_dir = vim.fn.stdpath("cache") .. "/ecsact-lsp"
	vim.fn.mkdir(cache_dir, "p")
	local lsp_exe_path = cache_dir .. "/ecsact_lsp_server"
	if vim.fn.has("win32") == 1 then
		lsp_exe_path = lsp_exe_path .. ".exe"
	end

	return lsp_exe_path
end

local lsp_is_starting = false
local function ensure_ecsact_lsp_started(current_buf)
	if current_buf == 0 or current_buf == nil then
		current_buf = vim.api.nvim_get_current_buf()
	end

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

	local has_fidget, fidget = pcall(require, "fidget")
	local fidget_progress = nil

	if has_fidget then
		fidget_progress = fidget.progress.handle.create({
			key = "ecsact.nvim",
			title = "ecsact.nvim lsp",
			message = "",
			lsp_client = { name = "ecsact.nvim" },
			percentage = 0,
			cancellable = true,
		})
	end

	--- @param message string
	local function update_progress(message)
		if has_fidget and fidget_progress then
			fidget_progress.message = message
		end
	end

	local function cancel_fidget(reason)
		update_progress(reason)
		if has_fidget and fidget_progress then
			fidget_progress:cancel()
		end
	end

	lsp_is_starting = true
	local lsp_exe_path = get_ecsact_lsp_path()

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
			cancel_fidget("failed to spawn bazel")
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

	if #clients == 0 then
		vim.fn.delete(lsp_exe_path)
	end

	-- Build the LSP server
	update_progress("building @ecsact//ecsact_lsp_server")
	run_bazel({ "build", "@ecsact//ecsact_lsp_server" }, function(code, stdout, stderr)
		if code ~= 0 then
			lsp_is_starting = false
			vim.notify("ecsact.nvim: bazel build failed\n" .. stderr, vim.log.levels.ERROR)
			cancel_fidget("failed to build @ecsact//ecsact_lsp_server")
			return
		end

		-- Query the output file path
		update_progress("finding location of @ecsact//ecsact_lsp_server")
		run_bazel({ "cquery", "@ecsact//ecsact_lsp_server", "--output=files" }, function(q_code, q_stdout, q_stderr)
			if q_code ~= 0 then
				lsp_is_starting = false
				vim.notify("ecsact.nvim: bazel cquery failed\n" .. q_stderr, vim.log.levels.ERROR)
				cancel_fidget("failed to cquery @ecsact//ecsact_lsp_server")
				return
			end

			local relative_path = vim.trim(q_stdout):gsub("\r", "")
			if relative_path == "" then
				lsp_is_starting = false
				vim.notify("ecsact.nvim: Could not resolve LSP path from bazel", vim.log.levels.ERROR)
				cancel_fidget()
				return
			end

			local full_path = bazel_root .. "/" .. relative_path
			-- Copy to cache for stability
			vim.uv.fs_copyfile(full_path, lsp_exe_path, { excl = false }, function(err)
				cancel_fidget()
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
		ensure_ecsact_lsp_started(args.buf)
	end,
})

vim.api.nvim_create_user_command("EcsactLspRefresh", function()
	local ecsact_lsp_clients = vim.lsp.get_clients({
		name = "ecsact",
	})

	local ecsact_lsp_bufs = {}

	for _, client in ipairs(ecsact_lsp_clients) do
		for buf, _ in pairs(client.attached_buffers) do
			table.insert(ecsact_lsp_bufs, buf)
		end

		pcall(function()
			client:stop(true)
		end)
	end

	local lsp_exe_path = get_ecsact_lsp_path()
	vim.defer_fn(function()
		if vim.fn.delete(lsp_exe_path) ~= 0 then
			vim.notify(string.format("ecsact.nvim: failed to delete %s", lsp_exe_path), vim.log.levels.ERROR)
		end
		for _, buf in ipairs(ecsact_lsp_bufs) do
			ensure_ecsact_lsp_started(buf)
		end
	end, 500)
end, {})

--- @param symbol ecsact.lsp.EcsactSymbolResult
local function goto_impl(symbol)
	local win = vim.api.nvim_get_current_win()

	local clangd_clients = vim.lsp.get_clients({
		name = "clangd",
	})

	if #clangd_clients == 0 then
		vim.notify("no clangd clients available")
		return
	end

	--- @type lsp.WorkspaceSymbolParams
	local params = { query = symbol.cpp.implementation }
	if params.query == "" then
		params.query = symbol.cpp.type
	end

	local finished_requests = 0

	--- @type lsp.WorkspaceSymbol[]
	local all_symbol_locations = {}

	local score_patterns = {
		vim.regex("\\v\\.ecsact\\.(c|cpp|cc|cxx)$"),
		vim.regex("\\v\\.ecsact\\.(h|hh|hpp|hxx)$"),
		vim.regex("\\v(c|cpp|cc|cxx)$"),
		vim.regex("\\vc$"),
	}

	--- @param loc lsp.WorkspaceSymbol
	--- @return number
	local function location_score(loc)
		for score, pattern in ipairs(score_patterns) do
			if pattern:match_str(loc.location.uri) then
				return score
			end
		end

		return #score_patterns + 1
	end

	local function done_all_requests()
		table.sort(all_symbol_locations, function(a, b)
			return location_score(a) > location_score(b)
		end)

		local entry = all_symbol_locations[1]

		if entry then
			local bufnr = vim.uri_to_bufnr(entry.location.uri)
			vim.api.nvim_win_set_buf(win, bufnr)
			if entry.location.range then
				vim.api.nvim_win_set_cursor(win, {
					entry.location.range.start.line + 1,
					entry.location.range.start.character,
				})
			end
		else
			vim.notify("ecsact impl not found", vim.log.levels.ERROR)
		end
	end

	for _, clangd in ipairs(clangd_clients) do
		--- @param err lsp.ResponseError|nil
		--- @param result lsp.WorkspaceSymbol[]|nil
		local function response_handler(err, result, context, config)
			finished_requests = finished_requests + 1
			result = result or {}

			for _, entry in ipairs(result) do
				table.insert(all_symbol_locations, entry)
			end

			if finished_requests == #clangd_clients then
				vim.schedule(done_all_requests)
			end

			if err then
				vim.notify(err.message, vim.log.levels.ERROR)
			end
		end

		local success = clangd:request("workspace/symbol", params, response_handler)

		if not success then
			finished_requests = finished_requests + 1
			if finished_requests == #clangd_clients then
				vim.schedule(done_all_requests)
			end
		end
	end
end

vim.api.nvim_create_user_command("EcsactLspGotoImpl", function()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local ecsact_lsp_clients = vim.lsp.get_clients({
		name = "ecsact",
	})

	assert(#ecsact_lsp_clients > 0, "no ecsact lsp clients available")

	for _, client in ipairs(ecsact_lsp_clients) do
		--- @type ecsact.lsp.EcsactSymbolParams
		local params = {
			textDocument = { uri = vim.uri_from_bufnr(0) },
			position = {
				line = cursor[1] - 1,
				character = cursor[2],
			},
		}

		---@diagnostic disable-next-line: param-type-mismatch
		local result = client:request_sync("ecsact/symbols", params)
		if result and result.result then
			goto_impl(result.result)
			return
		elseif result then
			vim.notify(result.err.message, vim.log.levels.ERROR)
		else
			vim.notify("no response from ecsact lsp", vim.log.levels.ERROR)
		end
	end
end, {})

return {
	-- for lazy.nvim
	setup = function() end,
}
