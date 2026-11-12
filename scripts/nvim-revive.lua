-- Neovim's half of tmux-revive. save.sh loads it into a running nvim over its socket to write
-- the editor's own session (tabs, splits, cursors, folds) and the text of every buffer not yet
-- written; restore.sh loads it into the new nvim to put that text back, unsaved, as it was.
local M = {}

local function write_private(path, lines)
	vim.fn.writefile(lines, path)
	vim.uv.fs_chmod(path, tonumber("600", 8))
end

-- save(DIR, TAG) -> "ok": DIR/nvim-TAG.vim (the session) and DIR/nvim-TAG.json (unsaved
-- buffers). It runs inside your editor every few minutes, so it leaves nothing behind: no
-- message, no SessionWritePost, the same 'sessionoptions' and v:this_session as before.
function M.save(dir, tag)
	local session, unsaved = dir .. "/nvim-" .. tag .. ".vim", dir .. "/nvim-" .. tag .. ".json"
	local ssop, this = vim.o.sessionoptions, vim.v.this_session
	-- A terminal buffer would rerun its command on restore.
	vim.opt.sessionoptions:remove({ "terminal", "options", "localoptions" })
	local ok, err = pcall(vim.cmd, "silent noautocmd mksession! " .. vim.fn.fnameescape(session))
	vim.o.sessionoptions, vim.v.this_session = ssop, this
	if not ok then
		return "error: " .. tostring(err)
	end
	vim.uv.fs_chmod(session, tonumber("600", 8))
	local bufs = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[b].modified and vim.bo[b].buftype == "" and vim.api.nvim_buf_is_loaded(b) then
			bufs[#bufs + 1] = {
				name = vim.api.nvim_buf_get_name(b),
				lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
				filetype = vim.bo[b].filetype,
			}
		end
	end
	write_private(unsaved, { vim.json.encode(bufs) })
	return "ok"
end

-- The swap file a killed nvim leaves behind would stop the restore at nvim's ATTENTION prompt.
-- When the nvim that owned it is gone and the snapshot is at least as new as it, the snapshot
-- has the same text (or newer), so the swap goes. A swap written after the snapshot may hold
-- edits the snapshot missed (a crash between saves): the file opens as it is and is recovered
-- from that swap once startup is over, quietly, instead of at nvim's recovery prompt.
local function on_swap(saved_at, to_recover)
	local info = vim.fn.swapinfo(vim.v.swapname)
	if info.error then
		return
	end
	local alive = info.pid and info.pid > 0 and info.host == vim.uv.os_gethostname() and vim.uv.kill(info.pid, 0) == 0
	if alive then
		return -- another nvim has the file open: nvim asks, as it always does
	end
	local st = vim.uv.fs_stat(vim.v.swapname)
	if st and saved_at and st.mtime.sec > saved_at and info.dirty == 1 then
		vim.v.swapchoice = "e"
		to_recover[vim.fn.fnamemodify(vim.fn.expand("<afile>"), ":p")] = vim.v.swapname
	else
		vim.v.swapchoice = "d"
	end
end

local function put_lines(b, lines)
	local cursors = {}
	for _, w in ipairs(vim.fn.win_findbuf(b)) do
		cursors[w] = vim.api.nvim_win_get_cursor(w)
	end
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	for w, c in pairs(cursors) do
		c[1] = math.min(c[1], #lines > 0 and #lines or 1)
		pcall(vim.api.nvim_win_set_cursor, w, c)
	end
end

local function read_unsaved(file)
	local ok, bufs = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
	end)
	local named, unnamed = {}, {}
	if not ok or type(bufs) ~= "table" then
		return named, unnamed
	end
	for _, e in ipairs(bufs) do
		if type(e) == "table" and type(e.lines) == "table" and type(e.name) == "string" then
			if e.name == "" then
				unnamed[#unnamed + 1] = e
			else
				named[vim.fn.fnamemodify(e.name, ":p")] = e
			end
		end
	end
	return named, unnamed
end

-- An unnamed buffer is not in a session: the empty window the session left for it takes it,
-- else a new listed buffer does.
local function put_unnamed(e)
	local b
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local wb = vim.api.nvim_win_get_buf(w)
		if not b and vim.api.nvim_buf_get_name(wb) == "" and vim.bo[wb].buftype == ""
			and not vim.bo[wb].modified and vim.api.nvim_buf_line_count(wb) == 1
			and vim.api.nvim_buf_get_lines(wb, 0, 1, false)[1] == "" then
			b = wb
		end
	end
	b = b or vim.api.nvim_create_buf(true, false)
	put_lines(b, e.lines)
	if type(e.filetype) == "string" and e.filetype ~= "" then
		vim.bo[b].filetype = e.filetype
	end
end

-- restore(): loaded with --cmd, before the session (-S) opens any file. A file's unsaved text
-- goes in as the session reads it, before the session puts the cursor back, so a cursor past
-- the end of the text on disk lands where it was.
function M.restore()
	local session, unsaved = vim.env.REVIVE_NVIM_SESSION, vim.env.REVIVE_NVIM_UNSAVED
	-- Not for the shells and programs this nvim starts.
	vim.env.REVIVE_NVIM_LUA, vim.env.REVIVE_NVIM_SESSION, vim.env.REVIVE_NVIM_UNSAVED = nil, nil, nil
	local st = session and vim.uv.fs_stat(session)
	local saved_at = st and st.mtime.sec
	local to_recover = {}
	local named, unnamed = {}, {}
	if unsaved and unsaved ~= "" then
		named, unnamed = read_unsaved(unsaved)
	end
	local group = vim.api.nvim_create_augroup("tmux_revive", { clear = true })
	vim.api.nvim_create_autocmd("SwapExists", {
		group = group,
		callback = function() on_swap(saved_at, to_recover) end,
	})
	-- Every read until startup is over: the session's :edit reads a file the argv already
	-- opened over again, since a read leaves 'modified' off.
	local taken, recovering = {}, false
	local function take(b, path)
		local e = named[path]
		if e and not recovering then -- :recover reads the file too -- a file to recover gets it too, so the session's cursor lands where it was
			put_lines(b, e.lines)
			taken[path] = b
		end
	end
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		callback = function(ev) take(ev.buf, vim.fn.fnamemodify(ev.file, ":p")) end,
	})
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		nested = true, -- the buffers it loads still go through SwapExists above
		callback = function()
			-- What the session did not open (a buffer listed but never shown) is loaded now.
			for path in pairs(named) do
				if not taken[path] then
					local b = vim.fn.bufadd(path)
					vim.bo[b].buflisted = true
					-- :edit, not bufload(), which skips SwapExists and stops at nvim's swap error.
					-- A file that is gone opens empty.
					pcall(vim.api.nvim_buf_call, b, function() vim.cmd("silent edit") end)
					take(b, path)
				end
			end
			for path, swap in pairs(to_recover) do
				local b = vim.fn.bufnr(path)
				if b > 0 then
					local cursors = {}
					for _, w in ipairs(vim.fn.win_findbuf(b)) do
						cursors[w] = vim.api.nvim_win_get_cursor(w)
					end
					recovering = true
					local ok = pcall(vim.api.nvim_buf_call, b, function()
						vim.cmd("silent recover! " .. vim.fn.fnameescape(swap))
					end)
					recovering = false
					for w, c in pairs(cursors) do
						pcall(vim.api.nvim_win_set_cursor, w, c)
					end
					if ok then
						taken[path] = b
						os.remove(swap) -- its text is in the buffer now, and in this nvim's own swap
					end
				end
			end
			for _, e in ipairs(unnamed) do
				put_unnamed(e)
			end
			-- Reading a file clears 'modified' after BufReadPost: set it again, so :q still warns.
			for _, b in pairs(taken) do
				if vim.api.nvim_buf_is_valid(b) then
					vim.bo[b].modified = true
				end
			end
			vim.v.this_session = "" -- the session was the snapshot's, not one of yours
			vim.api.nvim_del_augroup_by_id(group)
			-- restore.sh handed over copies made for this nvim alone.
			for _, f in ipairs({ session, unsaved }) do
				if f and f:match("/panes/nvim%.[%w]+$") then
					os.remove(f)
				end
			end
		end,
	})
end

-- Run as `nvim -l nvim-revive.lua save SOCKET DIR TAG`: the client save.sh uses. It asks the
-- editor first whether it is waiting at a prompt (hit-enter, a confirm, a pending key), when a
-- request would sit until you answer it: then it saves nothing and says "blocked".
if type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("nvim%-revive%.lua$") and arg[1] == "save" then
	local me = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", arg[2], { rpc = true })
	if not ok or chan == 0 then
		io.write("no editor\n")
		os.exit(1)
	end
	if vim.rpcrequest(chan, "nvim_get_mode").blocking then
		io.write("blocked\n")
		os.exit(1)
	end
	local res = vim.rpcrequest(chan, "nvim_exec_lua", "return dofile(...).save(select(2, ...))", { me, arg[3], arg[4] })
	io.write(tostring(res) .. "\n")
	os.exit(res == "ok" and 0 or 1)
end

return M
