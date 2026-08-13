for _, binding in ipairs({
	{ "SUPER + H", hl.dsp.focus({ direction = "left" }) },
	{ "SUPER + L", hl.dsp.focus({ direction = "right" }) },
	{ "SUPER + left", hl.dsp.focus({ direction = "left" }) },
	{ "SUPER + right", hl.dsp.focus({ direction = "right" }) },
	{ "SUPER + SHIFT + H", hl.dsp.window.move({ direction = "left" }) },
	{ "SUPER + SHIFT + L", hl.dsp.window.move({ direction = "right" }) },
	{ "SUPER + SHIFT + left", hl.dsp.window.move({ direction = "left" }) },
	{ "SUPER + SHIFT + right", hl.dsp.window.move({ direction = "right" }) },
	{ "SUPER + CTRL + J", hl.dsp.focus({ direction = "up" }) },
	{ "SUPER + CTRL + K", hl.dsp.focus({ direction = "down" }) },
	{ "SUPER + M", hl.dsp.layout("focus") },
}) do
	hl.bind(binding[1], binding[2])
end
