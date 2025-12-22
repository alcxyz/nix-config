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
	res := "2560x1440@60" // Target streaming resolution
	fmt.Printf("Bringing %s into focus at %s\n", Dongle, res)
	// Position it at 5120x0 (directly to the right of your ultrawide)
	run("hyprctl", "keyword", "monitor", fmt.Sprintf("%s, %s, 5120x0, 1", Dongle, res))
	run("hyprctl", "keyword", "workspace", fmt.Sprintf("%s, monitor:%s, default:true", GameWS, Dongle))
}

func streamOff() {
	fmt.Println("Parking the streaming monitor...")
	// Move it back to the void at a low resolution
	run("hyprctl", "keyword", "monitor", fmt.Sprintf("%s, 2560x1440@60, 10000x10000, 1", Dongle))
	run("hyprctl", "keyword", "workspace", fmt.Sprintf("%s, monitor:%s, default:true", GameWS, Ultrawide))
	// GUARD: Only load if NOT already loaded
	if !isLoopbackLoaded("GameLoopbackLocal") {
		fmt.Println("Enabling local audio loopback...")
		run("pactl", "load-module", "module-loopback", "source=GameAudioSink.monitor", "sink=@DEFAULT_SINK@", "media.name=GameLoopbackLocal")
	}
}

func isLoopbackLoaded(name string) bool {
	// Grep return code 0 means found
	cmd := exec.Command("sh", "-c", fmt.Sprintf("pactl list short modules | grep -q 'media.name=%s'", name))
	return cmd.Run() == nil
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
