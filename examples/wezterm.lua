local wezterm = require("wezterm")

package.path = package.path
  .. ";/Users/osvaldo/Workspace/wezterm-sesh/?.lua"
  .. ";/Users/osvaldo/Workspace/wezterm-sesh/?/init.lua"

local wezsesh = require("plugin")

local config = {}

wezsesh.setup({
  zoxide_path = "zoxide",
  inline_preview = false,
  sessions = {
    {
      name = "dotfiles",
      path = "~/dotfiles",
      startup_command = "nvim",
    },
  },
  wildcard = {
    {
      pattern = "~/Workspace/*",
      startup_command = "",
    },
  },
  default_session = {
    startup_command = "",
    preview_command = "",
  },
})

config.keys = config.keys or {}

table.insert(config.keys, {
  key = "s",
  mods = "LEADER",
  action = wezsesh.switch_workspace({
    hide_duplicates = true,
  }),
})

table.insert(config.keys, {
  key = "S",
  mods = "LEADER",
  action = wezsesh.switch_to_prev_workspace(),
})

table.insert(config.keys, {
  key = "g",
  mods = "LEADER",
  action = wezsesh.connect("~/Workspace/webapp/backend"),
})

return config
