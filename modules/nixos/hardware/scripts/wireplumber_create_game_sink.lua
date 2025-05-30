-- modules/nixos/hardware/wireplumber_create_game_sink.lua
Log.info("WirePlumber: Loading custom rule to create GameAudioSink")

local rule = {
  matches = {
    {
      -- This rule will match the PipeWire daemon itself, ensuring it runs once
      -- when WirePlumber connects to PipeWire.
      { "object.serial", "exists" }
    }
  },
  apply_once = true, -- Very important to prevent multiple creations
  actions = {
    create_device = {
      factory = "spa-node-factory",
      args = {
        ["factory.name"]    = "support.null-audio-sink", -- Standard factory for null sinks
        ["node.name"]       = "GameAudioSink",
        ["node.description"]= "Virtual_Sink_for_Games",
        ["media.class"]     = "Audio/Sink",
        ["audio.channels"]  = 2,
        ["audio.position"]  = "FL,FR"
        -- You can add other properties here if needed, e.g.:
        -- ["priority.driver"] = 2000, -- Higher priority
        -- ["node.autoconnect"] = false, -- Usually false for null sinks unless you want them to be default
      }
    }
  }
}

-- Add the rule to WirePlumber's processing
-- This depends on how WirePlumber is structured to load user rules.
-- A common way is to add to a global table if one is exposed,
-- or simply ensure this script is executed by WirePlumber.
-- For now, just defining the rule and having WirePlumber execute this script
-- (by placing it in a scanned directory) is often enough for `create_device`.
-- If WirePlumber expects rules to be added to a specific table (e.g., `main_rules`),
-- you would do: table.insert(main_rules, rule)
-- However, for `create_device` in a script placed in `main.lua.d`, it should just run.

-- For safety and to ensure it's processed, let's explicitly add it to a common rules table
-- if it exists, otherwise it should still be processed if the script is loaded.
if type(default_lua_rules) == "table" then
  table.insert(default_lua_rules, rule)
  Log.info("WirePlumber: GameAudioSink rule added to default_lua_rules.")
elseif type(alsa_monitor) == "table" and type(alsa_monitor.rules) == "table" then
  -- Fallback if default_lua_rules isn't the main one for device creation
  table.insert(alsa_monitor.rules, rule)
  Log.info("WirePlumber: GameAudioSink rule added to alsa_monitor.rules.")
else
  Log.warn("WirePlumber: Could not find a global rules table to insert GameAudioSink rule. create_device should still work if script is loaded.")
  -- The create_device action itself should be processed when the script is loaded by WirePlumber
  -- from a directory like main.lua.d or conf.d
end
