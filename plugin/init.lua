local wezterm = require("wezterm")
local act = wezterm.action
local mux = wezterm.mux

local is_windows = wezterm.target_triple:find("windows") ~= nil
local event_prefix = "wezsesh.workspace_switcher"

local defaults = {
  zoxide_path = "zoxide",
  zoxide_extra_args = "",
  default_workspace = "~",
  sessions = {},
  wildcard = {},
  blacklist = {},
  include_workspaces = true,
  include_zoxide = true,
  include_sessions = true,
  inline_preview = false,
  preview_max_chars = 80,
  default_session = {
    startup_command = "",
    preview_command = "",
  },
  workspace_formatter = function(label, choice)
    local prefix = "[path]"
    if choice.kind == "workspace" then
      prefix = "[ws]"
    elseif choice.kind == "zoxide" then
      prefix = "[zx]"
    elseif choice.kind == "session" then
      prefix = "[cfg]"
    end

    local text = string.format("%s %s", prefix, label)
    if choice.preview and choice.preview ~= "" then
      text = text .. " -- " .. choice.preview
    end

    return text
  end,
}

local state = nil

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end

  local out = {}
  for k, v in pairs(value) do
    out[k] = deepcopy(v)
  end
  return out
end

local function merge_into(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge_into(dst[k], v)
    else
      dst[k] = deepcopy(v)
    end
  end
end

local function cfg_with(opts)
  if not state then
    state = deepcopy(defaults)
  end

  local merged = deepcopy(state)
  merge_into(merged, opts or {})
  return merged
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run_child_process(command)
  local process_args
  if is_windows then
    process_args = { "cmd", "/c", command }
  else
    process_args = { os.getenv("SHELL") or "sh", "-lc", command }
  end

  local ok, stdout, stderr = wezterm.run_child_process(process_args)
  if not ok then
    wezterm.log_error("wezsesh child process failed: " .. command .. "\n" .. (stderr or ""))
    return "", false
  end

  return stdout or "", true
end

local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" then
      out[#out + 1] = line
    end
  end
  return out
end

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function expand_home(path)
  if not path or path == "" then
    return ""
  end
  if path == "~" then
    return wezterm.home_dir
  end
  if starts_with(path, "~/") then
    return wezterm.home_dir .. path:sub(2)
  end
  return path
end

local function shorten_home(path)
  if not path or path == "" then
    return ""
  end
  if path == wezterm.home_dir then
    return "~"
  end
  if starts_with(path, wezterm.home_dir .. "/") then
    return "~" .. path:sub(#wezterm.home_dir + 1)
  end
  return path
end

local function glob_to_lua_pattern(glob)
  local out = { "^" }
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      out[#out + 1] = "[^/]*"
    elseif c == "?" then
      out[#out + 1] = "[^/]"
    elseif c == "[" then
      local j = i + 1
      while j <= #glob and glob:sub(j, j) ~= "]" do
        j = j + 1
      end
      if j <= #glob then
        out[#out + 1] = glob:sub(i, j)
        i = j
      else
        out[#out + 1] = "%["
      end
    else
      if c:match("[%^%$%(%)%%%.%[%]%+%-%?]") then
        out[#out + 1] = "%" .. c
      else
        out[#out + 1] = c
      end
    end
    i = i + 1
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

local function glob_match(glob, value)
  local pat = glob_to_lua_pattern(glob)
  local ok, matched = pcall(function()
    return value:match(pat) ~= nil
  end)
  return ok and matched
end

local function workspace_exists(name)
  for _, workspace in ipairs(mux.get_workspace_names()) do
    if workspace == name then
      return true
    end
  end
  return false
end

local function list_workspace_names()
  local names = {}
  for _, workspace in ipairs(mux.get_workspace_names()) do
    names[#names + 1] = workspace
  end
  return names
end

local function directory_exists(path)
  if path == "" then
    return false
  end

  if is_windows then
    local cmd = "if exist " .. shell_quote(path .. "\\NUL") .. " (echo 1)"
    local out, ok = run_child_process(cmd)
    return ok and out:find("1", 1, true) ~= nil
  end

  local cmd = "test -d " .. shell_quote(path) .. " && printf 1"
  local out, ok = run_child_process(cmd)
  return ok and out == "1"
end

local function workspace_label_from_path(path)
  return shorten_home(path)
end

local function parse_sessions(cfg)
  local out = {}
  for _, raw in ipairs(cfg.sessions or {}) do
    local path = expand_home(raw.path or "")
    local workspace = raw.name
    if not workspace or workspace == "" then
      workspace = workspace_label_from_path(path)
    end

    out[#out + 1] = {
      kind = "session",
      workspace = workspace,
      path = path,
      startup_command = raw.startup_command or "",
      preview_command = raw.preview_command or "",
      disable_startup_command = raw.disable_startup_command == true,
    }
  end
  return out
end

local function find_session_by_name(cfg, name)
  for _, session in ipairs(parse_sessions(cfg)) do
    if session.workspace == name then
      return session
    end
  end
  return nil
end

local function find_session_by_path(cfg, path)
  for _, session in ipairs(parse_sessions(cfg)) do
    if session.path == path then
      return session
    end
  end
  return nil
end

local function find_wildcard(cfg, path)
  for _, wc in ipairs(cfg.wildcard or {}) do
    local pattern = expand_home(wc.pattern or "")
    if pattern ~= "" and glob_match(pattern, path) then
      return {
        startup_command = wc.startup_command or "",
        preview_command = wc.preview_command or "",
        disable_startup_command = wc.disable_startup_command == true,
      }
    end
  end
  return nil
end

local function substitute_path(cmd, path)
  return (cmd or ""):gsub("{}", path)
end

local function resolve_startup_command(cfg, path, session, explicit_command)
  if explicit_command and explicit_command ~= "" then
    return substitute_path(explicit_command, path)
  end

  if session and session.startup_command ~= "" then
    return substitute_path(session.startup_command, path)
  end

  local wildcard = find_wildcard(cfg, path)
  if wildcard and not wildcard.disable_startup_command and wildcard.startup_command ~= "" then
    return substitute_path(wildcard.startup_command, path)
  end

  if session and session.disable_startup_command then
    return ""
  end

  return substitute_path(cfg.default_session.startup_command or "", path)
end

local function resolve_preview_command(cfg, path, session)
  if session and session.preview_command ~= "" then
    return substitute_path(session.preview_command, path)
  end

  local wildcard = find_wildcard(cfg, path)
  if wildcard and wildcard.preview_command ~= "" then
    return substitute_path(wildcard.preview_command, path)
  end

  return substitute_path(cfg.default_session.preview_command or "", path)
end

local function command_preview(cfg, path, session)
  if not cfg.inline_preview then
    return ""
  end

  local command = resolve_preview_command(cfg, path, session)
  if command == "" then
    return ""
  end

  local out, ok = run_child_process(command)
  if not ok then
    return ""
  end

  local line = split_lines(out)[1] or ""
  if #line > cfg.preview_max_chars then
    line = line:sub(1, cfg.preview_max_chars) .. "..."
  end
  return line
end

local function query_zoxide_list(cfg, extra_args)
  local command = shell_quote(cfg.zoxide_path) .. " query -l"
  local add = extra_args or cfg.zoxide_extra_args or ""
  if add ~= "" then
    command = command .. " " .. add
  end

  local out, ok = run_child_process(command)
  if not ok then
    return {}
  end

  local paths = {}
  for _, line in ipairs(split_lines(out)) do
    local path = line:gsub("^%s+", "")
    if path ~= "" then
      paths[#paths + 1] = path
    end
  end
  return paths
end

local function query_zoxide_path(cfg, query)
  local command = shell_quote(cfg.zoxide_path) .. " query " .. shell_quote(query)
  local out, ok = run_child_process(command)
  if not ok then
    return nil
  end

  local line = split_lines(out)[1]
  if not line or line == "" then
    return nil
  end

  return line
end

local function add_zoxide(cfg, path)
  local command = shell_quote(cfg.zoxide_path) .. " add " .. shell_quote(path)
  run_child_process(command)
end

local function is_blacklisted(cfg, label)
  for _, pattern in ipairs(cfg.blacklist or {}) do
    local ok, matched = pcall(function()
      return label:find(pattern) ~= nil
    end)
    if ok and matched then
      return true
    end
  end
  return false
end

local function make_choice_id(kind, value)
  return kind .. "\31" .. value
end

local function build_choices(cfg, opts, window)
  local choices = {}
  local lookup = {}
  local workspace_ids = {}
  local seen_labels = {}

  local include_workspaces = opts.include_workspaces
  local include_sessions = opts.include_sessions
  local include_zoxide = opts.include_zoxide

  if include_workspaces == nil then
    include_workspaces = cfg.include_workspaces
  end
  if include_sessions == nil then
    include_sessions = cfg.include_sessions
  end
  if include_zoxide == nil then
    include_zoxide = cfg.include_zoxide
  end

  local current_workspace = opts.hide_active and window:active_workspace() or ""

  local function append_choice(choice)
    if is_blacklisted(cfg, choice.label) then
      return
    end

    if opts.hide_duplicates and seen_labels[choice.label] then
      return
    end

    seen_labels[choice.label] = true

    local id = make_choice_id(choice.kind, choice.id)
    lookup[id] = choice

    local rendered = cfg.workspace_formatter(choice.label, choice)
    choices[#choices + 1] = {
      id = id,
      label = rendered,
    }
  end

  if include_workspaces then
    for _, workspace in ipairs(list_workspace_names()) do
      workspace_ids[workspace] = true
      if workspace ~= current_workspace then
        append_choice({
          kind = "workspace",
          id = workspace,
          workspace = workspace,
          label = workspace,
          path = "",
          preview = "",
        })
      end
    end
  end

  if include_sessions then
    for _, session in ipairs(parse_sessions(cfg)) do
      session.preview = command_preview(cfg, session.path, session)
      append_choice({
        kind = "session",
        id = session.workspace,
        workspace = session.workspace,
        label = session.workspace,
        path = session.path,
        session = session,
        preview = session.preview,
      })
    end
  end

  if include_zoxide then
    for _, path in ipairs(query_zoxide_list(cfg, opts.extra_args)) do
      local label = workspace_label_from_path(path)

      -- Match smart_workspace_switcher behavior: zoxide labels that already
      -- exist as workspaces are omitted.
      if not workspace_ids[label] then
        local session = find_session_by_path(cfg, path)
        append_choice({
          kind = "zoxide",
          id = path,
          workspace = label,
          label = label,
          path = path,
          session = session,
          preview = command_preview(cfg, path, session),
        })
      end
    end
  end

  return choices, lookup
end

local function build_spawn_args(startup_command)
  if not startup_command or startup_command == "" then
    return nil
  end

  if is_windows then
    return { "cmd", "/c", startup_command }
  end

  local shell = os.getenv("SHELL") or "sh"
  return { shell, "-lc", startup_command .. "; exec \"${SHELL:-sh}\" -l" }
end

local function switch_workspace(window, pane, workspace)
  window:perform_action(
    act.SwitchToWorkspace({
      name = workspace,
    }),
    pane
  )
end

local function spawn_workspace(window, pane, workspace, path, startup_command)
  local spawn = {
    label = "Workspace: " .. workspace,
    cwd = path,
  }

  local args = build_spawn_args(startup_command)
  if args then
    spawn.args = args
  end

  window:perform_action(
    act.SwitchToWorkspace({
      name = workspace,
      spawn = spawn,
    }),
    pane
  )
end

local function perform_choice(cfg, window, pane, choice, explicit_startup_command)
  wezterm.GLOBAL.wezsesh_previous_workspace = window:active_workspace()

  if choice.kind == "workspace" then
    switch_workspace(window, pane, choice.workspace)
    wezterm.emit(event_prefix .. ".chosen", window, choice.workspace)
    return
  end

  local startup = resolve_startup_command(cfg, choice.path, choice.session, explicit_startup_command)

  if workspace_exists(choice.workspace) then
    switch_workspace(window, pane, choice.workspace)
    wezterm.emit(event_prefix .. ".chosen", window, choice.workspace)
    add_zoxide(cfg, choice.path)
    return
  end

  spawn_workspace(window, pane, choice.workspace, choice.path, startup)
  add_zoxide(cfg, choice.path)
  wezterm.emit(event_prefix .. ".created", window, choice.workspace)
end

local function resolve_input_to_choice(cfg, input)
  if workspace_exists(input) then
    return {
      kind = "workspace",
      workspace = input,
    }
  end

  local named_session = find_session_by_name(cfg, input)
  if named_session then
    return {
      kind = "session",
      workspace = named_session.workspace,
      path = named_session.path,
      session = named_session,
    }
  end

  local expanded = expand_home(input)
  if directory_exists(expanded) then
    local workspace = workspace_label_from_path(expanded)
    return {
      kind = "zoxide",
      workspace = workspace,
      path = expanded,
      session = find_session_by_path(cfg, expanded),
    }
  end

  local zoxide_path = query_zoxide_path(cfg, input)
  if zoxide_path then
    local workspace = workspace_label_from_path(zoxide_path)
    return {
      kind = "zoxide",
      workspace = workspace,
      path = zoxide_path,
      session = find_session_by_path(cfg, zoxide_path),
    }
  end

  return nil
end

local pub = {}

function pub.setup(opts)
  state = cfg_with(opts)
  return pub
end

function pub.switch_workspace(opts)
  local cfg = cfg_with(opts)

  return wezterm.action_callback(function(window, pane)
    wezterm.emit(event_prefix .. ".start", window, pane)

    local choices, lookup = build_choices(cfg, opts or {}, window)
    if #choices == 0 then
      wezterm.emit(event_prefix .. ".canceled", window, pane)
      return
    end

    window:perform_action(
      act.InputSelector({
        title = "Choose Workspace",
        description = "Enter accepts, Esc cancels, / filters",
        fuzzy_description = "Workspace to switch: ",
        fuzzy = true,
        choices = choices,
        action = wezterm.action_callback(function(inner_window, inner_pane, id, _)
          if not id then
            wezterm.emit(event_prefix .. ".canceled", inner_window, inner_pane)
            return
          end

          local choice = lookup[id]
          if not choice then
            wezterm.emit(event_prefix .. ".canceled", inner_window, inner_pane)
            return
          end

          wezterm.emit(event_prefix .. ".selected", inner_window, choice)

          if opts and opts.prompt_for_startup_command then
            inner_window:perform_action(
              act.PromptInputLine({
                description = "Startup command (optional):",
                action = wezterm.action_callback(function(prompt_window, prompt_pane, line)
                  perform_choice(cfg, prompt_window, prompt_pane, choice, line or "")
                end),
              }),
              inner_pane
            )
            return
          end

          perform_choice(cfg, inner_window, inner_pane, choice, opts and opts.startup_command or "")
        end),
      }),
      pane
    )
  end)
end

function pub.connect(name, opts)
  local cfg = cfg_with(opts)

  return wezterm.action_callback(function(window, pane)
    local choice = resolve_input_to_choice(cfg, name)
    if not choice then
      wezterm.log_error("wezsesh: no workspace/path found for '" .. tostring(name) .. "'")
      return
    end

    perform_choice(cfg, window, pane, choice, opts and opts.startup_command or "")
  end)
end

function pub.switch_to_prev_workspace()
  return wezterm.action_callback(function(window, pane)
    local previous = wezterm.GLOBAL.wezsesh_previous_workspace
    local current = window:active_workspace()

    if not previous or previous == "" or previous == current then
      return
    end

    wezterm.GLOBAL.wezsesh_previous_workspace = current
    window:perform_action(
      act.SwitchToWorkspace({
        name = previous,
      }),
      pane
    )
    wezterm.emit(event_prefix .. ".switched_to_prev", window, previous)
  end)
end

function pub.apply_to_config(config, opts)
  config.keys = config.keys or {}

  table.insert(config.keys, {
    key = "s",
    mods = "LEADER",
    action = pub.switch_workspace(opts),
  })

  table.insert(config.keys, {
    key = "S",
    mods = "LEADER",
    action = pub.switch_to_prev_workspace(),
  })
end

wezterm.on(event_prefix .. ".selected", function(window, _)
  wezterm.GLOBAL.wezsesh_previous_workspace = window:active_workspace()
end)

return pub
