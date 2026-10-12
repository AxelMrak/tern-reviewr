local ui = tern.ui

local function split0(text)
	local result = {}
	for part in string.gmatch(text or "", "([^%z]+)") do
		table.insert(result, part)
	end
	return result
end

local function split_lines(text)
	local result = {}
	for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
		table.insert(result, (line:gsub("\r$", "")))
	end
	if #result > 0 and result[#result] == "" then
		table.remove(result)
	end
	return result
end

local function parse_diff(path, text, rows)
	local old_line, new_line = 0, 0
	for _, line in split_lines(text) do
		if line:match("^@@ ") then
			local old_start, new_start = line:match("^@@ %-(%d+)[^+]*%+(%d+)")
			old_line, new_line = tonumber(old_start) or 0, tonumber(new_start) or 0
			table.insert(rows, { file = true, path = path, text = line })
		elseif line:sub(1, 4) == "diff" or line:sub(1, 10) == "index " or line:sub(1, 10) == "new file m" or line:sub(1, 10) == "deleted fi" or line:sub(1, 4) == "--- " or line:sub(1, 4) == "+++ " then
			-- File and patch metadata are represented by the path and hunk rows.
		elseif line:sub(1, 1) == " " then
			table.insert(rows, { path = path, kind = "context", old = old_line, new = new_line, text = line:sub(2) })
			old_line += 1
			new_line += 1
		elseif line:sub(1, 1) == "+" then
			table.insert(rows, { path = path, kind = "add", old = nil, new = new_line, text = line:sub(2) })
			new_line += 1
		elseif line:sub(1, 1) == "-" then
			table.insert(rows, { path = path, kind = "delete", old = old_line, new = nil, text = line:sub(2) })
			old_line += 1
		elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
			table.insert(rows, { path = path, kind = "binary", text = line })
		end
	end
end

local function is_alive(pane)
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function start_diff(state, cx)
	local function finish()
		if not is_alive(cx.pane) then return end
		state.loading = false
		local selected_exists = false
		for _, row in state.rows do
			if row.path == state.selected_file then selected_exists = true; break end
		end
		if not selected_exists then state.selected_file = state.rows[1] and state.rows[1].path or nil end
		state.cursor = 1
		for index, row in state.rows do
			if row.path == state.selected_file and (row.kind == "context" or row.kind == "add" or row.kind == "delete") then
				state.cursor = index
				break
			end
		end
		state.range_start = nil
		cx:render()
	end
	local function run_paths(paths, tracked)
		state.rows = {}
		local index = 1
		local function next_file()
			if not is_alive(cx.pane) then return end
			local path = paths[index]
			if not path then finish(); return end
			index += 1
			local argv
			if tracked[path] then
				argv = { "git", "diff", "--no-ext-diff", "--no-color", "--unified=3", "HEAD", "--", path }
			else
				argv = { "git", "diff", "--no-index", "--no-color", "--unified=3", "--", "/dev/null", path }
			end
			tern.process.run(argv, { cwd = state.root, timeout_ms = 15000 }, function(result)
				if not is_alive(cx.pane) then return end
				if result.status == 0 or result.status == 1 then
					parse_diff(path, result.stdout .. result.stderr, state.rows)
				end
				next_file()
			end)
		end
		next_file()
	end
	tern.process.run({ "git", "diff", "--name-only", "-z", "--no-renames", "HEAD", "--" }, { cwd = state.root, timeout_ms = 10000 }, function(changed)
		if not is_alive(cx.pane) then return end
		if changed.status ~= 0 then state.error = changed.stderr; finish(); return end
		local tracked, paths = {}, split0(changed.stdout)
		for _, path in paths do tracked[path] = true end
		tern.process.run({ "git", "ls-files", "--others", "--exclude-standard", "-z" }, { cwd = state.root, timeout_ms = 10000 }, function(untracked)
			if not is_alive(cx.pane) then return end
			if untracked.status ~= 0 then state.error = untracked.stderr; finish(); return end
			for _, path in split0(untracked.stdout) do
				if not tracked[path] then table.insert(paths, path) end
			end
			run_paths(paths, tracked)
		end)
	end)
end

local function line_number(row)
	return tostring(row.new or row.old or "-")
end

local function selectable(rows, path)
	local result = {}
	for index, row in rows do
		if (not path or row.path == path) and (row.kind == "context" or row.kind == "add" or row.kind == "delete") then
			table.insert(result, index)
		end
	end
	return result
end

local function selected_range(state)
	if state.range_start then
		return math.min(state.range_start, state.cursor), math.max(state.range_start, state.cursor)
	end
	return state.cursor, state.cursor
end

local function comment_anchor(state)
	local first, last = selected_range(state)
	local a, b = state.rows[first], state.rows[last]
	if not a or not b or a.path ~= b.path or a.kind == "binary" or b.kind == "binary" then
		return nil
	end
	return a.path, line_number(a), line_number(b)
end

local function range_description(state)
	local path, first, last = comment_anchor(state)
	if not path then return "Select a range within one file" end
	return "Range " .. path .. ":" .. first .. (last ~= first and "–" .. last or "") .. " · j/k extend · c comment"
end

local function file_paths(state)
	local paths, seen = {}, {}
	for _, row in state.rows do
		if row.path and not seen[row.path] then
			seen[row.path] = true
			table.insert(paths, row.path)
		end
	end
	return paths
end

local function first_line(state, path)
	for index, row in state.rows do
		if row.path == path and (row.kind == "context" or row.kind == "add" or row.kind == "delete") then
			return index
		end
	end
	return 1
end

local function render_files(state, max_lines)
	local paths, children, selected = file_paths(state), {}, nil
	for index, path in paths do
		local added, deleted = 0, 0
		for _, row in state.rows do
			if row.path == path then
				if row.kind == "add" then added += 1 elseif row.kind == "delete" then deleted += 1 end
			end
		end
		local key = "f" .. tostring(index)
		if path == state.selected_file then selected = "main.body.files.files." .. key end
		table.insert(children, ui.node("item", {
			key = key,
			label = { ui.span(state.reviewed[path] and "[x] " or "[ ] ", state.reviewed[path] and "success" or "muted"), ui.span(path, "path") },
			value = { ui.span("+" .. added, "success"), ui.span(" -" .. deleted, "error") },
		}))
	end
	return ui.node("list", { key = "files", selected = selected, max = { lines = max_lines }, empty = { ui.span("No changed files", "muted") } }, children)
end

local function render_diff(state, max_lines)
	local children = {}
	local first, last = selected_range(state)
	for index, row in state.rows do
		if row.path == state.selected_file then
			local label, tone
			if row.file then
				label, tone = { ui.span(row.text, "muted") }, "muted"
			elseif row.kind == "binary" then
				label, tone = { ui.span(row.text, "warning") }, "warning"
			else
				local sign = row.kind == "add" and "+" or (row.kind == "delete" and "-" or " ")
				local sign_style = row.kind == "add" and "success" or (row.kind == "delete" and "error" or "muted")
				local selected_range = state.range_start and index >= first and index <= last
				local marker = index == state.cursor and "> " or (selected_range and "| " or "  ")
				local numbers = string.format("%4s %4s", tostring(row.old or ""), tostring(row.new or ""))
				label = { ui.span(marker .. numbers .. " " .. sign .. " ", selected_range and "mark" or sign_style), ui.span(row.text, "code") }
				if row.kind == "add" then tone = "success" elseif row.kind == "delete" then tone = "error" end
			end
			table.insert(children, ui.node("item", { key = "r" .. tostring(index), label = label, tone = tone }))
		end
	end
	local selected = state.cursor and ("main.body.diff.diff.r" .. tostring(state.cursor)) or nil
	return ui.node("list", { key = "diff", selected = selected, max = { lines = max_lines }, virtual = true, empty = { ui.span("Select a changed file", "muted") } }, children)
end

local function render_comments(state, max_lines)
	local children = {}
	for index, comment in state.comments do
		table.insert(children, ui.node("item", {
			key = "c" .. tostring(index),
			label = { ui.span(comment.path .. ":" .. comment.start .. (comment.finish ~= comment.start and "–" .. comment.finish or ""), "path strong") },
			detail = comment.text,
			tone = "accent",
		}))
	end
	return ui.node("list", { key = "comments", selected = state.comment_cursor and ("main.body.comments.c" .. tostring(state.comment_cursor)) or nil, max = { lines = max_lines }, virtual = true, empty = { ui.span("No comments yet", "muted") } }, children)

end
local function truncate_comment(text, max_chars)
	local length = utf8.len(text)
	if not length or length <= max_chars then return text end
	local end_byte = utf8.offset(text, max_chars + 1)
	return end_byte and text:sub(1, end_byte - 1) .. "…" or text
end

local function comment_preview_line(comment, max_chars)
	local path = comment.path:match("([^/]+)$") or comment.path
	local anchor = path .. ":" .. comment.start
	if comment.finish ~= comment.start then anchor ..= "–" .. comment.finish end
	return ui.text({
		ui.span("C " .. anchor .. " · ", "accent"),
		ui.span(truncate_comment(comment.text, max_chars), "muted"),
	})
end

local function render_comment_preview(state, count, max_chars)
	local children = {}
	local first = math.max(1, #state.comments - count + 1)
	for index = first, #state.comments do
		table.insert(children, comment_preview_line(state.comments[index], max_chars))
	end
	return ui.node("col", { key = "comment-preview", role = "plugin.tern-reviewr.comment-preview", gap = "xs" }, children)
end
local function render_compact_summary(state, max_rows, comment_chars)
	local paths, counts = file_paths(state), {}
	local added, deleted = 0, 0
	for _, path in paths do counts[path] = { added = 0, deleted = 0 } end
	for _, row in state.rows do
		local file = counts[row.path]
		if file then
			if row.kind == "add" then file.added += 1; added += 1
			elseif row.kind == "delete" then file.deleted += 1; deleted += 1 end
		end
	end

	local summary = {}
	if state.loading then
		summary = { ui.span("Scanning changes…", "muted") }
	else
		summary = {
			ui.span(#paths .. " files", "strong"),
			ui.span(" +" .. added, "success"),
			ui.span("/-" .. deleted, "error"),
		}
	end
	local children = { ui.text(summary) }
	local room = max_rows - 1
	local comment_room = #state.comments > 0 and state.panel ~= "comments" and room > 0
	local file_room = math.max(0, room - (comment_room and 1 or 0))
	local file_count = math.min(#paths, file_room)
	local more_files = #paths > file_room and file_room > 1
	if more_files then file_count -= 1 end
	for index = 1, file_count do
		local path, file = paths[index], counts[paths[index]]
		table.insert(children, ui.text({
			ui.span("+" .. file.added, "success"),
			ui.span("/-" .. file.deleted .. " ", "error"),
			ui.span(path:match("([^/]+)$") or path, "path"),
		}))
	end
	if more_files then
		table.insert(children, ui.text({ ui.span("+" .. (#paths - file_count) .. " more files", "muted") }))
	end
	if comment_room then
		table.insert(children, comment_preview_line(state.comments[#state.comments], comment_chars))
	end
	return ui.node("col", { key = "summary", role = "plugin.tern-reviewr.summary", gap = "xs" }, children)
end


local function move_selection(state, delta)
	if state.panel == "comments" then
		state.comment_cursor = math.clamp((state.comment_cursor or 1) + delta, 1, math.max(1, #state.comments))
	elseif state.focus == "files" then
		local paths, selected = file_paths(state), 1
		if #paths == 0 then return end
		for index, path in paths do if path == state.selected_file then selected = index; break end end
		selected = math.clamp(selected + delta, 1, #paths)
		state.selected_file = paths[selected]
		state.cursor = first_line(state, state.selected_file)
		state.range_start, state.status = nil, nil
	else
		local rows = selectable(state.rows, state.selected_file)
		if #rows == 0 then return end
		for index, row in rows do
			if row == state.cursor then state.cursor = rows[math.clamp(index + delta, 1, #rows)] or row; break end
		end
		if state.range_start then state.status = range_description(state) end
	end
end


local function comments_message(state)
	local out = { "Review feedback on uncommitted changes in `" .. state.root .. "`. Please address each comment." }
	for _, comment in state.comments do
		table.insert(out, "")
		table.insert(out, "- `" .. comment.path .. ":" .. comment.start .. (comment.finish ~= comment.start and "-" .. comment.finish or "") .. "` — " .. comment.text)
	end
	return table.concat(out, "\n")
end

local function agent_label(agent)
	return agent.label or agent.title or agent.model or ("pane " .. tostring(agent.pane))
end

local function queue_send(state, cx)
	local agent = state.targets[state.target_index]
	if not agent then state.status = "No Tern agent in this repository"; return end
	if #state.comments == 0 then state.status = "Add at least one comment first"; return end
	if not state.window_key then state.status = "Direct send unavailable: Tern window identity is missing"; return end
	local request = {
		window = state.window_key,
		block = cx.pane,
		root = state.root,
		target = agent.pane,
		message = comments_message(state),
	}
	tern.fs.write(state.outbox .. "/" .. tostring(cx.pane) .. ".json", tern.json.encode(request))
	state.waiting_send = true
	state.confirm_send = false
	state.status = "Sending to " .. agent_label(agent) .. "…"
	local function poll()
		if not state.waiting_send or not is_alive(cx.pane) then return end
		local ack_path = state.outbox .. "/" .. tostring(cx.pane) .. ".ack"
		if tern.fs.exists(ack_path) then
			local ok, ack = pcall(function() return tern.json.decode(tern.fs.read(ack_path, 4096)) end)
			tern.fs.remove(ack_path)
			state.waiting_send = false
			if ok and ack.ok then
				state.status = "Sent to " .. agent_label(agent) .. " (comments kept here)"
				cx:toast("success", "Review comments sent", agent_label(agent))
			else
				state.status = "Direct send failed: " .. (ok and (ack.error or "unknown error") or tostring(ack))
			end
			cx:render()
			return
		end
		tern.timer(150, poll)
	end
	tern.timer(150, poll)
end

local function submit(state, cx)
	state.confirm_send = false
	queue_send(state, cx)
end

local function view(state, cx)
	-- shortcut: Tern can scale PiP pixels without changing cx.cols/cx.rows; use reported block size until float bounds are exposed.
	local cols, rows = state.view_cols or cx.cols, state.view_rows or cx.rows
	local compact = cols < 64 or rows < 24
	local tiny = compact
	local preview_rows = not compact and state.panel ~= "comments" and #state.comments > 0 and math.min(2, #state.comments) or 0
	local max_lines = math.max(4, math.min(22, rows - (tiny and 8 or 10) - preview_rows))
	local summary_rows = compact and math.max(#state.comments > 0 and 2 or 1, math.min(4, max_lines - 4)) or 0
	local panel_lines = compact and math.max(2, max_lines - summary_rows - 1) or max_lines
	local header
	if compact then
		local items = {
			ui.text({ ui.span("REVIEWR", "strong") }),
			ui.node("row", { grow = 1 }),
			ui.badge(state.focus == "files" and "FILES" or "DIFF", "accent"),
		}
		if tiny then table.insert(items, ui.badge("C" .. #state.comments, "info")) end
		header = ui.row(items)
	else
		header = ui.row({
			ui.text({ ui.span("REVIEWR", "strong") }),
			ui.node("row", { grow = 1 }),
			ui.badge("Files", state.focus == "files" and "accent" or "muted"),
			ui.badge("Diff", state.focus == "diff" and "accent" or "muted"),
			ui.badge(state.targets[state.target_index] and agent_label(state.targets[state.target_index]) or "No agent", state.targets[state.target_index] and "success" or "warning"),
		})
	end
	local root_label = state.root:match("([^/]+)/?$") or state.root
	local subtitle = state.loading and "Loading uncommitted changes…" or (state.error or root_label)
	local summary = compact and render_compact_summary(state, summary_rows, math.max(12, math.min(32, cols - 20))) or nil
	local preview = not compact and state.panel ~= "comments" and #state.comments > 0 and render_comment_preview(state, 2, math.max(20, math.min(80, cols - 28))) or nil
	local body
	if state.panel == "comments" then
		local content = { ui.text({ ui.span("Review comments", "strong") }), render_comments(state, panel_lines) }
		if compact then table.insert(content, 1, summary) end
		body = ui.node("col", { key = "body", grow = 1, min = { h = 0 }, gap = "xs" }, content)
	else
		local diff = ui.node("col", {
			key = "diff",
			role = state.focus == "diff" and "plugin.tern-reviewr.focused" or "plugin.tern-reviewr.panel",
			grow = 1,
			min = { w = "32ch", h = 0 },
			gap = "xs",
		}, {
			ui.text({ ui.span("DIFF / " .. (state.selected_file or "SELECT A FILE"), "path strong") }),
			render_diff(state, panel_lines),
		})
		local files_props = {
			key = "files",
			role = state.focus == "files" and "plugin.tern-reviewr.focused" or "plugin.tern-reviewr.panel",
			min = { w = "18ch", h = 0 },
			gap = "xs",
		}
		if compact then files_props.grow = 1 else files_props.basis = 0.28 end
		local files = ui.node("col", files_props, {
			ui.text({ ui.span("FILES", "muted") }),
			render_files(state, panel_lines),
		})
		if compact then
			body = ui.node("col", { key = "body", grow = 1, min = { h = 0 }, gap = "xs" }, {
				summary,
				state.focus == "files" and files or diff,
			})
		else
			body = ui.node("row", { key = "body", align = "stretch", grow = 1, min = { h = 0 }, gap = "md" }, { diff, files })
		end
	end
	local children = { header, ui.text({ ui.span(subtitle, state.error and "error" or "muted") }) }
	if preview then table.insert(children, preview) end
	table.insert(children, body)
	if state.status and not tiny then table.insert(children, ui.text({ ui.span(state.status, "info") })) end
	local hint = ui.text({
		ui.span("Tab focus  j/k move  v range  c comment  m comments  x reviewed  [ ] agent  s send · " .. #state.comments .. (#state.comments == 1 and " comment" or " comments") .. "  Esc cancel", "muted"),
	})
	local dock
	if not tiny then dock = ui.row({ hint }) end
	local layer
	if state.editing then
		layer = ui.col({ ui.node("overlay", { key = "comment", head = "Comment on selected lines", size = "sm", modal = true }, {
			ui.text({ ui.span(state.buffer == "" and "Type comment…" or state.buffer, "code") }),
			ui.text({ ui.span("Enter saves · Esc cancels", "muted") }),
		}) })
	elseif state.confirm_send then
		layer = ui.col({ ui.node("overlay", { key = "send", head = "Send review comments?", size = "sm", modal = true }, {
			ui.text({ ui.span(state.targets[state.target_index] and agent_label(state.targets[state.target_index]) or "No Tern agent available", "strong") }),
			ui.text({ ui.span("Enter confirms · Esc cancels", "muted") }),
		}) })
	end
	return { main = ui.col(children), dock = dock, layer = layer }
end

tern.block.define("review", {
	init = function(cx, args, saved)
		local root = args[1] or cx.cwd or "."
		local decoded = {}
		if args[2] then
			local ok, value = pcall(tern.json.decode, args[2])
			if ok and type(value) == "table" then decoded = value end
		end
		local state = saved or { comments = {} }
		state.root = root
		state.targets = decoded
		state.window_key = args[3] ~= "" and args[3] or nil
		state.outbox = tern.plugin.data .. "/outbox"
		tern.fs.mkdir(state.outbox)
		state.target_index = math.clamp(state.target_index or 1, 1, math.max(1, #decoded))
		state.comments = state.comments or {}
		state.reviewed = state.reviewed or {}
		state.panel = state.panel or "changes"
		state.focus = state.focus or "diff"
		state.cursor = state.cursor or 1
		state.view_cols, state.view_rows = cx.cols, cx.rows
		state.rows = {}
		state.loading = true
		state.status = nil
		state.error = nil
		start_diff(state, cx)
		return state
	end,
	title = function() return "Review uncommitted changes" end,
	view = view,
	resize = function(state, cols, rows)
		state.view_cols, state.view_rows = cols, rows
	end,
	key = function(state, key, cx)
		local name = key.name
		if state.editing then
			if name == "escape" then state.editing, state.buffer = false, ""
			elseif name == "enter" then
				local path, first, last = comment_anchor(state)
				if path and state.buffer:match("%S") then
					table.insert(state.comments, { path = path, start = first, finish = last, text = state.buffer })
					state.comment_cursor = #state.comments
					state.status = "Comment added"
				else state.status = "Comment needs text and a single-file range" end
				state.editing, state.buffer = false, ""
			elseif name == "backspace" then
				local offset = utf8.offset(state.buffer, -1)
				state.buffer = offset and state.buffer:sub(1, offset - 1) or ""
			elseif name == "paste" and key.text then state.buffer ..= key.text:gsub("\r?\n", " ")
			elseif key.text and not key.ctrl and not key.alt and not key.meta then state.buffer ..= key.text end
			return true
		end
		if state.confirm_send then
			if name == "escape" then state.confirm_send = false
			elseif name == "enter" then submit(state, cx) end
			return true
		end
		if name == "escape" then
			if state.range_start then state.range_start = nil; state.status = "Range cancelled"; return true end
			if state.panel == "comments" then state.panel = "changes"; return true end
			return false
		elseif name == "tab" then
			if state.panel == "comments" then state.panel = "changes" else state.focus = state.focus == "files" and "diff" or "files" end
			return true
		elseif name == "m" then state.panel = state.panel == "comments" and "changes" or "comments"; return true
		elseif name == "[" then state.target_index = math.max(1, state.target_index - 1); state.status = nil; return true
		elseif name == "]" then state.target_index = math.min(#state.targets, state.target_index + 1); state.status = nil; return true
		elseif name == "v" and state.panel == "changes" and state.focus == "diff" then
			if state.range_start then state.range_start = nil; state.status = "Range cleared"
			else state.range_start = state.cursor; state.status = range_description(state) end
			return true
		elseif name == "c" and state.panel == "changes" and state.focus == "diff" then
			if not comment_anchor(state) then state.status = "Select a diff line first" else state.editing, state.buffer = true, "" end
			return true
		elseif name == "x" and state.panel == "changes" then
			local path = state.selected_file
			if path then
				state.reviewed[path] = not state.reviewed[path] or nil
				state.status = (state.reviewed[path] and "Reviewed: " or "Not reviewed: ") .. path
			else
				state.status = "Select a file first"
			end
			return true
		elseif name == "s" then state.confirm_send = true; return true
		elseif name == "j" or name == "down" then move_selection(state, 1); return true
		elseif name == "k" or name == "up" then move_selection(state, -1); return true
		elseif name == "r" and key.ctrl then
			state.loading, state.error, state.rows = true, nil, {}
			start_diff(state, cx)
			return true
		end
		return false
	end,
	event = function(state, ev)
		if ev.ev == "select" and state.panel == "comments" then
			state.comment_cursor = tonumber(tostring(ev.item):match("c(%d+)$"))
		elseif ev.ev == "select" and state.panel == "changes" then
			local item = tostring(ev.item)
			local file_index = tonumber(item:match("f(%d+)$"))
			if file_index then
				state.selected_file = file_paths(state)[file_index]
				state.cursor = first_line(state, state.selected_file)
				state.range_start = nil
				state.focus = "diff"
			else
				local row_index = tonumber(item:match("r(%d+)$"))
				local row = row_index and state.rows[row_index]
				if row and row.path == state.selected_file and (row.kind == "context" or row.kind == "add" or row.kind == "delete") then
					state.cursor, state.focus = row_index, "diff"
				end
			end
		end
	end,
	save = function(state)
		return {
			comments = state.comments,
			comment_cursor = state.comment_cursor,
			panel = state.panel,
			target_index = state.target_index,
			selected_file = state.selected_file,
			focus = state.focus,
			cursor = state.cursor,
			reviewed = state.reviewed,
		}
	end,
})
