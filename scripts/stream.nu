# nix-config/scripts/stream.nu

# Setup the streaming environment on the HDMI Dongle
def main [state: string, res: string = "1920x1080@60"] {
    let dongle = "HDMI-A-1" # Update this to your HDMI port name
    let game_ws = "9"

    if $state == "on" {
        # Enable the phantom monitor at desired resolution
        hyprctl keyword monitor $"($dongle), ($res), auto, 1"
        # Pin the gaming workspace to that monitor
        hyprctl keyword workspace $"($game_ws), monitor:($dongle), default:true"
        print $"Streaming display ($dongle) is ON at ($res) (Workspace ($game_ws))"
    } else {
        # Disable the dongle
        hyprctl keyword monitor $"($dongle), disable"
        print "Streaming display is OFF"
    }
}
