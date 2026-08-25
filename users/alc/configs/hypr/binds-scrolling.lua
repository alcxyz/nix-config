local ordinary_column_widths = { 0.25, 0.333, 0.5, 0.666, 1 }
-- A stable QA matrix rather than a copy of every historical site breakpoint:
-- phone, large phone, tablet, compact desktop, laptop, desktop, and wide.
local frontend_viewport_widths = { 390, 430, 768, 900, 1024, 1280, 1440, 1920 }

local function frontend_column_widths(monitor)
	if monitor == nil or monitor.width == nil or monitor.width <= 0 then
		return ordinary_column_widths
	end

	local scale = monitor.scale or 1
	local logical_width = monitor.width / scale
	local widths = {}

	for _, viewport_width in ipairs(frontend_viewport_widths) do
		if viewport_width < logical_width then
			table.insert(widths, viewport_width / logical_width)
		end
	end

	table.insert(widths, 1)
	return widths
end

local function normalized_column_widths(widths)
	if type(widths) == "table" then
		return widths
	end

	if type(widths) == "string" then
		local parsed = {}
		for width in string.gmatch(widths, "[^,]+") do
			local number = tonumber(width)
			if number ~= nil then
				table.insert(parsed, number)
			end
		end
		if #parsed > 0 then
			return parsed
		end
	end

	return ordinary_column_widths
end

local function column_widths_for_context(monitor, workspace)
	if workspace ~= nil and workspace.id == 10 then
		return frontend_column_widths(monitor)
	end

	local monitor_overrides = rawget(_G, "alc_scrolling_column_widths_by_monitor")
	if monitor ~= nil and type(monitor_overrides) == "table" then
		return normalized_column_widths(monitor_overrides[monitor.name])
	end

	return ordinary_column_widths
end

local function resize_column_from_context(direction)
	local window = hl.get_active_window()
	local monitor = hl.get_active_monitor()
	local workspace = hl.get_active_special_workspace() or hl.get_active_workspace()
	local column = window and window.layout and window.layout.column

	if column == nil or type(column.width) ~= "number" then
		return
	end

	local widths = column_widths_for_context(monitor, workspace)
	local current_width = column.width
	local target_width = nil
	local epsilon = 0.0001

	if direction == "+" then
		for _, width in ipairs(widths) do
			if width > current_width + epsilon then
				target_width = width
				break
			end
		end
		target_width = target_width or widths[1]
	else
		for index = #widths, 1, -1 do
			if widths[index] < current_width - epsilon then
				target_width = widths[index]
				break
			end
		end
		target_width = target_width or widths[#widths]
	end

	hl.dispatch(hl.dsp.layout(string.format("colresize %.6f", target_width)))
end

-- Keep the exact action callable through `hyprctl eval` for diagnostics.
alc_resize_scrolling_column = resize_column_from_context

-- Horizontal column navigation.
for _, binding in ipairs({
	{ "SUPER + H", "focus l" },
	{ "SUPER + L", "focus r" },
	{ "SUPER + left", "focus l" },
	{ "SUPER + right", "focus r" },
	{ "SUPER + SHIFT + H", "swapcol l" },
	{ "SUPER + SHIFT + L", "swapcol r" },
	{ "SUPER + SHIFT + left", "swapcol l" },
	{ "SUPER + SHIFT + right", "swapcol r" },
	{ "SUPER + CTRL + N", "fit tobeg" },
	{ "SUPER + CTRL + M", "fit toend" },
	{ "SUPER + CTRL + comma", "fit visible" },
	{ "SUPER + CTRL + period", "fit all" },
	{ "SUPER + CTRL + Y", "movewindowto l" },
	{ "SUPER + CTRL + U", "promote" },
}) do
	hl.bind(binding[1], hl.dsp.layout(binding[2]))
end

-- Workspace 10 cycles a stable frontend QA viewport matrix. Individual hosts
-- can narrow the general-purpose list further on specific outputs.
hl.bind("SUPER + comma", function()
	resize_column_from_context("-")
end)
hl.bind("SUPER + period", function()
	resize_column_from_context("+")
end)
