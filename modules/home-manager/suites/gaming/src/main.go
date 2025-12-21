package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

const (
	Ultrawide = "DP-5"
	Dongle    = "HDMI-A-3"
	GameWS    = "1"
)

type HyprMonitor struct {
	Name string `json:"name"`
}

func isDongleActive() bool {
	out, err := exec.Command("hyprctl", "monitors", "-j").Output()
	if err != nil {
		return false
	}
	var monitors []HyprMonitor
	json.Unmarshal(out, &monitors)

	for _, m := range monitors {
		if m.Name == Dongle {
			return true
		}
	}
	return false
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func streamOn() {
	res := "1920x1080@60"
	fmt.Printf("Activating Stream Mode: %s on %s\n", res, Dongle)
	run("hyprctl", "keyword", "monitor", fmt.Sprintf("%s, %s, auto, 1", Dongle, res))
	run("hyprctl", "keyword", "workspace", fmt.Sprintf("%s, monitor:%s, default:true", GameWS, Dongle))
}

func isLoopbackLoaded(name string) bool {
	// Grep return code 0 means found
	cmd := exec.Command("sh", "-c", fmt.Sprintf("pactl list short modules | grep -q 'media.name=%s'", name))
	return cmd.Run() == nil
}

func streamOff() {
	fmt.Println("Deactivating Stream Mode...")
	run("hyprctl", "keyword", "monitor", fmt.Sprintf("%s, disable", Dongle))
	run("hyprctl", "keyword", "workspace", fmt.Sprintf("%s, monitor:%s, default:true", GameWS, Ultrawide))

	// GUARD: Only load if NOT already loaded
	if !isLoopbackLoaded("GameLoopbackLocal") {
		fmt.Println("Enabling local audio loopback...")
		run("pactl", "load-module", "module-loopback", "source=GameAudioSink.monitor", "sink=@DEFAULT_SINK@", "media.name=GameLoopbackLocal")
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: stream [on|off|toggle]")
		os.Exit(1)
	}

	mode := os.Args[1]

	switch mode {
	case "on":
		streamOn()
	case "off":
		streamOff()
	case "toggle":
		if isDongleActive() {
			streamOff()
		} else {
			streamOn()
		}
	default:
		fmt.Printf("Unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
