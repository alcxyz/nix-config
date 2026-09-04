local scripts = "~/.config/hypr/scripts"
local term = "foot"
local file_manager = "nautilus"
local mail = "thunderbird"
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
hl.bind("SUPER + G", hl.dsp.exec_cmd(mail))
hl.bind("SUPER + F", hl.dsp.exec_cmd(file_manager))
hl.bind("SUPER + T", hl.dsp.exec_cmd("t3code-desktop"))

-- System actions.
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("dms ipc call notifications open"))
hl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("dms ipc call wallpaper next"))
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("dms ipc call bar toggle index 0"))

-- Window management.
hl.bind("SUPER + W", hl.dsp.window.close())
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

for i = 1, 10 do
	local key = i % 10
	hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = i }))
	hl.bind("SUPER + ALT + " .. key, hl.dsp.window.move({ workspace = i, follow = false }))
end

-- Shift changes number-row symbols, so use physical keycodes when moving.
for i = 1, 10 do
	hl.bind("SUPER + SHIFT + code:" .. (i + 9), hl.dsp.window.move({ workspace = i }))
end

-- Scratchpad.
hl.bind("SUPER + SHIFT + ESCAPE", hl.dsp.window.move({ workspace = "special:" }))
hl.bind("SUPER + ALT + ESCAPE", hl.dsp.window.move({ workspace = "special:", follow = false }))
hl.bind("SUPER + ESCAPE", hl.dsp.workspace.toggle_special(""))

-- Function keys: single/double tap handler and raw Alt passthrough.
for i = 1, 6 do
	local key = "F" .. i
	hl.bind(key, hl.dsp.exec_cmd(scripts .. "/fkey_handler.sh " .. key .. " " .. i))
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
