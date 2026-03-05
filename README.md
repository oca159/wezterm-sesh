# wezsesh (WezTerm plugin)

`wezsesh` is a wezterm plugin to manage sessions, it is inspired by the popular sesh tool.

It follows the WezTerm workspace recipe model (`SwitchToWorkspace` + mux workspaces) and uses a fuzzy `InputSelector` flow inspired by `smart_workspace_switcher.wezterm`.

## What it does

- Fuzzy workspace picker inside WezTerm (`InputSelector` with `fuzzy = true`)
- Sources in picker:
  - existing WezTerm workspaces
  - zoxide paths
  - optional configured sessions
- Connect/switch behavior:
  - existing workspace: switch directly
  - path/zoxide/session: create+switch via `SwitchToWorkspace({ name = ..., spawn = { cwd = ... } })`
- Previous workspace toggle
- Optional startup command (global, session, wildcard, prompt)
- Optional inline preview text in picker labels

## Install (local plugin)

In your `~/.wezterm.lua`, add this line to use the plugin:

```lua
local wezsesh = wezterm.plugin.require("https://github.com/oca159/wezterm-sesh")
```

## Basic setup

```lua
local wezsesh = wezterm.plugin.require("https://github.com/oca159/wezterm-sesh")

local config = {}

wezsesh.setup({
	zoxide_path = "zoxide",
	inline_preview = true,
	default_session = {
		startup_command = "nvim",
		preview_command = "",
	},
	workspace_formatter = function(label, choice)
		local prefix = "[path]"
		local display_color = "#cdd6f4"
		if choice.kind == "workspace" then
			prefix = ": "
			display_color = "#fab387"
		elseif choice.kind == "zoxide" then
			prefix = ": "
		elseif choice.kind == "session" then
			prefix = ": "
			display_color = "#89b4fa"
		end

		local text = string.format("%s %s", prefix, label)
		if choice.preview and choice.preview ~= "" then
			text = text .. " -- " .. choice.preview
		end

		return wezterm.format({
			{ Attribute = { Italic = false } },
			{ Foreground = { Color = display_color } },
			{ Background = { Color = "#1e1e2e" } },
			{ Text = prefix .. label },
		})
	end,
	sessions = {
		{
			name = "aws credentials",
			path = "~/.aws",
			startup_command = "nvim credentials",
		},
		{
			name = "dotfiles",
			path = "~/dotfiles",
			startup_command = "nvim",
		},
		{
			name = "nix",
			path = "~/dotfiles/nix",
			startup_command = "nvim flake.nix",
		},
		{
			name = "tmux",
			path = "~/dotfiles/tmux",
			startup_command = "nvim tmux.conf",
		},
		{
			name = "wezterm",
			path = "~/dotfiles/wezterm",
			startup_command = "nvim wezterm.lua",
		},
	},
})

wezsesh.apply_to_config(config, {
  hide_duplicates = true,
  hide_active = false,
})

config.keys = config.keys or {}

-- open fuzzy picker
 table.insert(config.keys, {
  key = "s",
  mods = "LEADER",
  action = wezsesh.switch_workspace(),
 })

-- switch to previous workspace
 table.insert(config.keys, {
  key = "S",
  mods = "LEADER",
  action = wezsesh.switch_to_prev_workspace(),
 })

-- direct connect to a path/workspace
 table.insert(config.keys, {
  key = "g",
  mods = "LEADER",
  action = wezsesh.connect("~/Workspace/webapp/backend"),
 })

return config
```

## Picker/Connect options

`switch_workspace(opts)` supports:

- `extra_args` (`string`): appended to `zoxide query -l`
- `hide_duplicates` (`boolean`)
- `hide_active` (`boolean`)
- `include_workspaces` (`boolean`)
- `include_zoxide` (`boolean`)
- `include_sessions` (`boolean`)
- `startup_command` (`string`): force startup command for created workspace
- `prompt_for_startup_command` (`boolean`): ask for startup command after choice

`setup(opts)` supports:

- `zoxide_path` (`string`)
- `zoxide_extra_args` (`string`)
- `sessions` (`table[]`):
  - `name`, `path`, `startup_command`, `preview_command`, `disable_startup_command`
- `wildcard` (`table[]`):
  - `pattern`, `startup_command`, `preview_command`, `disable_startup_command`
- `default_session.startup_command`
- `default_session.preview_command`
- `blacklist` (`string[]` pattern list)
- `inline_preview` (`boolean`)
- `preview_max_chars` (`number`)
- `workspace_formatter(label, choice)` function

## Events

`wezsesh` emits:

- `wezsesh.workspace_switcher.start`
- `wezsesh.workspace_switcher.selected`
- `wezsesh.workspace_switcher.chosen`
- `wezsesh.workspace_switcher.created`
- `wezsesh.workspace_switcher.canceled`
- `wezsesh.workspace_switcher.switched_to_prev`

## References

- WezTerm workspace recipe: <https://wezterm.org/recipes/workspaces.html>
- Smart workspace switcher inspiration: <https://github.com/MLFlexer/smart_workspace_switcher.wezterm>
