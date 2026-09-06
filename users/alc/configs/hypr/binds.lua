local term = "foot"
local file_manager = "nautilus"
local lock = "lock-screen"

-- Help and session.
hl.bind("SUPER + Q", hl.dsp.exec_cmd(lock))
-- The K850 lock-logo action on F11 emits XF86ScreenSaver outside F-key mode.
hl.bind("XF86ScreenSaver", hl.dsp.exec_cmd(lock))
hl.bind("SUPER + SHIFT + Q", hl.dsp.exec_cmd(lock .. " --display-off-immediately"))
hl.bind("SUPER + BACKSPACE", hl.dsp.exec_cmd("dms ipc call powermenu toggle"))
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("dms ipc call spotlight toggle"))

-- Applications.
hl.bind("ALT + RETURN", hl.dsp.exec_cmd(term))
hl.bind("SUPER + B", hl.dsp.exec_cmd("zen --no-remote -profile /home/alc/.zen/alcxyz"))
hl.bind("SUPER + V", hl.dsp.exec_cmd('helium --profile-directory="Profile 2"'))
hl.bind("SUPER + X", hl.dsp.exec_cmd('helium --profile-directory="Profile 1" --remote-debugging-port=9222'))
hl.bind("SUPER + Z", hl.dsp.exec_cmd('brave --profile-directory="Profile 1" --remote-debugging-port=9223'))
hl.bind("SUPER + T", hl.dsp.exec_cmd("hyprland-mail-workspace"))
hl.bind("SUPER + P", hl.dsp.focus({ workspace = 7 }))
hl.bind("SUPER + SHIFT + P", hl.dsp.window.move({ workspace = 7 }))
hl.bind("SUPER + ALT + P", hl.dsp.window.move({ workspace = 7, follow = false }))
hl.bind("SUPER + G", hl.dsp.focus({ workspace = 8 }))
hl.bind("SUPER + SHIFT + G", hl.dsp.window.move({ workspace = 8 }))
hl.bind("SUPER + ALT + G", hl.dsp.window.move({ workspace = 8, follow = false }))
hl.bind("SUPER + F", hl.dsp.exec_cmd(file_manager))

-- System actions.
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("dms ipc call notifications open"))
hl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("dms ipc call wallpaper next"))
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("dms ipc call bar toggle index 0"))

-- Window management.
local function close_active_window()
	local window = hl.get_active_window()

	-- Only Battle.net enters the managed-runtime close path. Everything else,
	-- including similarly hosted Wine windows, keeps Hyprland's normal close.
	if window
		and window.class == "steam_app_default"
		and window.title == "Battle.net"
	then
		hl.dispatch(hl.dsp.exec_cmd("hyprland-close-active-window"))
		return
	end

	hl.dispatch(hl.dsp.window.close())
end

hl.bind("SUPER + W", close_active_window)
hl.bind("SUPER + S", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + RETURN", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind("SUPER + O", hl.dsp.exec_cmd("dms ipc call hypr toggleOverview"))

-- Workspace navigation and movement.
for _, key in ipairs({ "J", "down" }) do
	hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = "r-1" }))
	hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = "r-1" }))
	hl.bind("SUPER + ALT + " .. key, hl.dsp.window.move({ workspace = "r-1", follow = false }))
end
for _, key in ipairs({ "K", "up" }) do
	hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = "r+1" }))
	hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = "r+1" }))
	hl.bind("SUPER + ALT + " .. key, hl.dsp.window.move({ workspace = "r+1", follow = false }))
end
hl.bind("SUPER + TAB", hl.dsp.focus({ workspace = "previous" }))
hl.bind("ALT + TAB", hl.dsp.focus({ direction = "down" }))

local function remote_workspace_target(workspace_id)
	local workspace = hl.get_workspace(workspace_id)
	local monitor = workspace and workspace.monitor or nil

	-- Workspaces assigned to the focused monitor continue to use the regular
	-- focus bindings.
	if not monitor or monitor.focused then
		return nil, nil
	end

	return monitor, workspace
end

local function restore_focus_after(action)
	local focused_window = hl.get_active_window()
	local focused_monitor = hl.get_monitor("current")

	action()

	-- Hyprland 0.56's monitor workspace methods focus their target internally.
	-- Restore the exact window when possible so remote actions leave the user's
	-- effective focus unchanged.
	if focused_window then
		hl.dispatch(hl.dsp.focus({ window = focused_window }))
	elseif focused_monitor then
		hl.dispatch(hl.dsp.focus({ monitor = focused_monitor }))
	end
end

local function show_workspace_without_focus(workspace_id)
	local monitor, workspace = remote_workspace_target(workspace_id)
	if monitor then
		restore_focus_after(function()
			monitor:set_workspace({ workspace = workspace })
		end)
	end
end

local function remote_workspace_action(workspace_id)
	return function()
		show_workspace_without_focus(workspace_id)
	end
end

for i = 1, 10 do
	local key = i % 10
	hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = i }))
	hl.bind("SUPER + ALT + " .. key, hl.dsp.window.move({ workspace = i, follow = false }))
	hl.bind("SUPER + CTRL + " .. key, remote_workspace_action(i))
end

-- Shift changes number-row symbols, so use physical keycodes when moving.
for i = 1, 10 do
	hl.bind("SUPER + SHIFT + code:" .. (i + 9), hl.dsp.window.move({ workspace = i }))
end

-- Scratchpad.
hl.bind("SUPER + SHIFT + ESCAPE", hl.dsp.window.move({ workspace = "special:" }))
hl.bind("SUPER + ALT + ESCAPE", hl.dsp.window.move({ workspace = "special:", follow = false }))
hl.bind("SUPER + ESCAPE", hl.dsp.workspace.toggle_special(""))

-- Function keys: a single tap selects the numbered workspace and a second tap
-- within the timeout toggles the shared scratch workspace. Ctrl applies the
-- same gesture to the workspace's non-focused monitor without moving focus.
local fkey_double_tap_ms = 300
local pending_fkey_tap = nil
local fkey_tap_generation = 0

local function toggle_special_without_focus(workspace_id)
	local monitor = remote_workspace_target(workspace_id)
	if not monitor then
		return
	end

	restore_focus_after(function()
		hl.dispatch(hl.dsp.focus({ monitor = monitor }))
		hl.dispatch(hl.dsp.workspace.toggle_special(""))
	end)
end

local function fkey_action(workspace_id, remote)
	local tap_id = (remote and "remote:" or "local:") .. workspace_id

	return function()
		-- A remote gesture is meaningful only while its workspace belongs to a
		-- non-focused monitor. Do not arm a double tap for a local no-op.
		if remote and not remote_workspace_target(workspace_id) then
			return
		end

		if pending_fkey_tap == tap_id then
			pending_fkey_tap = nil
			fkey_tap_generation = fkey_tap_generation + 1

			if remote then
				toggle_special_without_focus(workspace_id)
			else
				hl.dispatch(hl.dsp.workspace.toggle_special(""))
			end
			return
		end

		pending_fkey_tap = tap_id
		fkey_tap_generation = fkey_tap_generation + 1
		local generation = fkey_tap_generation
		hl.timer(function()
			if fkey_tap_generation == generation then
				pending_fkey_tap = nil
			end
		end, { timeout = fkey_double_tap_ms, type = "oneshot" })

		if remote then
			show_workspace_without_focus(workspace_id)
		else
			hl.dispatch(hl.dsp.focus({ workspace = workspace_id }))
		end
	end
end

for i = 1, 6 do
	local key = "F" .. i
	hl.bind(key, fkey_action(i, false))
	hl.bind("CTRL + " .. key, fkey_action(i, true))
	hl.bind("ALT + " .. key, hl.dsp.exec_cmd("wtype -k " .. key), { release = true })
end

-- Mouse integration.
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.bind("SUPER + CTRL + mouse_up", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + CTRL + mouse_down", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "r+1" }))
hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "r-1" }))

-- Window rules.
hl.window_rule({ name = "foot-opacity", match = { class = "^(foot)$" }, opacity = 0.98 })
hl.window_rule({ name = "dropterm-opacity", match = { class = "^(dropterm)$" }, opacity = 0.90 })
hl.window_rule({
	name = "helium-opaque",
	match = { class = "^(helium)$" },
	opacity = "1.0 override 1.0 override 1.0 override",
})

-- Layout switching. The Lua callback updates the live config without the
-- deprecated hyprctl keyword interface.
hl.bind("SUPER + CTRL + S", function()
	hl.config({ general = { layout = "scrolling" } })
end)
hl.bind("SUPER + CTRL + SHIFT + S", function()
	hl.config({ general = { layout = "dwindle" } })
end)

-- Audio controls.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })
hl.bind("F10", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
hl.bind("F9", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
hl.bind("F8", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })

-- Screenshots and quick tools.
hl.bind("ALT + SHIFT + code:12", hl.dsp.exec_cmd("dms screenshot full"))
hl.bind("ALT + SHIFT + code:13", hl.dsp.exec_cmd("dms screenshot region"))
hl.bind("ALT + SHIFT + code:14", hl.dsp.exec_cmd("dms screenshot window"))
hl.bind("SUPER + N", hl.dsp.exec_cmd("dms ipc call notepad toggle"))
hl.bind("ALT + SPACE", hl.dsp.exec_cmd("dropterm-toggle"))

require("binds-scrolling")
