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
	{ "SUPER + comma", "colresize -conf" },
	{ "SUPER + period", "colresize +conf" },
}) do
	hl.bind(binding[1], hl.dsp.layout(binding[2]))
end
