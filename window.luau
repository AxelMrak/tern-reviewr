local window_key = tern.getenv("TERN_WINDOW_KEY") or (tostring(tern.now()) .. "-" .. tostring(math.random(1, 2147483647)))
local outbox = tern.plugin.data .. "/outbox"
tern.fs.mkdir(outbox)

local function inside(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function acknowledge(request_path, ok, message)
	local ack_path = request_path:gsub("%.json$", ".ack")
	tern.fs.write(ack_path, tern.json.encode({ ok = ok, error = message }))
end

local function poll_requests(cx)
	for _, name in tern.fs.list(outbox) do
		if name:match("^%d+%.json$") then
			local request_path = outbox .. "/" .. name
			local ok, request = pcall(function() return tern.json.decode(tern.fs.read(request_path, 65536)) end)
			if ok and request.window == window_key and window_key then
				tern.fs.remove(request_path)
				local listed, agents = pcall(function() return cx.agents:list() end)
				if not listed then acknowledge(request_path, false, tostring(agents)); return end
				local target
				for _, agent in agents do
					if agent.pane == request.target and type(agent.cwd) == "string" and inside(request.root, agent.cwd) then
						target = agent
						break
					end
				end
				if not target then acknowledge(request_path, false, "Target agent left this repository or session"); return end
				local sent, send_error = pcall(function()
					cx.agents:ask(request.target, request.message)
				end)
				acknowledge(request_path, sent, sent and nil or tostring(send_error))
			elseif not ok then
				tern.log.warn("discarding invalid send request", name, request)
				tern.fs.remove(request_path)
			end
		end
	end
	tern.timer(250, poll_requests)
end

tern.timer(250, poll_requests)

local function open_review(cx)
	local focused = cx.session:focused()
	local pane = focused and cx.session:pane(focused)
	local cwd = pane and pane.cwd
	if not cwd then
		cx:toast("error", "Focus a pane in the repository first")
		return
	end
	tern.process.run({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd, timeout_ms = 3000 }, function(result, next_cx)
		if result.status ~= 0 then
			next_cx:toast("error", "The focused pane is not in a Git repository", result.stderr)
			return
		end
		local root = result.stdout:gsub("%s+$", "")
		local targets = {}
		local focused_target
		for _, agent in next_cx.agents:list() do
			if type(agent.cwd) == "string" and inside(root, agent.cwd) then
				local target = {
					pane = agent.pane,
					cwd = agent.cwd,
					label = type(agent.model) == "string" and agent.model or ("pane " .. tostring(agent.pane)),
				}
				if agent.pane == focused then
					focused_target = target
				else
					table.insert(targets, target)
				end
			end
		end
		if focused_target then table.insert(targets, 1, focused_target) end
		local args = { root, tern.json.encode(targets), window_key }
		local review = next_cx:new_block("tern-reviewr.review", args, "beside", { focus = true })
		if not review then
			next_cx:toast("error", "Tern Reviewr is not ready on this host")
			return
		end
		if #targets == 0 then
			next_cx:toast("info", "No Tern agent found in this repository", "Diff review is available; direct send needs a matching agent")
		end
		local floated, why = next_cx.layout:float(review, focused, "br", { focus = true })
		if floated then
			next_cx.layout:focus(review)
		else
			next_cx:toast("info", "Review opened beside the focused pane", why or "Float unavailable")
		end
	end)
end


local function focus_review_float(cx)
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local layout = tab and cx.session:layout(tab)
	local function is_review_float(pane_id)
		local pane = cx.session:pane(pane_id)
		if not pane then return false end
		local label = (tostring(pane.title or "") .. " " .. tostring(pane.program or "")):lower()
		return label:find("review uncommitted changes", 1, true) ~= nil or label:find("lazygit", 1, true) ~= nil
	end
	local target
	if layout then
		if is_review_float(focused) then
			target = focused
		else
			for _, float in layout.floats do
				if float.over == focused and is_review_float(float.pane) then
					target = float.pane
					break
				end
			end
		end
	end
	if target then
		cx.layout:focus(target)
	else
		cx:toast("info", "No Reviewr or Lazygit float in the current tab")
	end
end

tern.command({
	id = "focus_float",
	title = "Focus Reviewr or Lazygit float",
	icon = "terminal",
	run = focus_review_float,
})

tern.command({
	id = "open",
	title = "Review uncommitted changes",
	icon = "git-branch",
	keys = { "ctrl+alt+shift+r" },
	run = open_review,
})
