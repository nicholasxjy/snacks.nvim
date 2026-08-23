local M = {}

local uv = vim.uv or vim.loop

---@type table<snacks.Picker, table<string, {pending?: boolean, status?: table<string, string>}>>
local picker_git_status = setmetatable({}, { __mode = "k" })

---@param root string
---@param path string
local function git_path(root, path)
  return svim.fs.normalize(vim.fs.joinpath(root, path), { _fast = true, expand_env = false })
end

---@param root string
---@param output string
---@return table<string, string>
local function parse_git_status(root, output)
  local status = {}
  local entries = vim.split(output, "\0", { trimempty = true })
  local i = 1
  while i <= #entries do
    local xy, file = entries[i]:match("^(..) (.*)$")
    if xy and file then
      status[git_path(root, file)] = xy
      if xy:find("[RC]") then
        local renamed = entries[i + 1]
        if renamed then
          status[git_path(root, renamed)] = xy
          i = i + 1
        end
      end
    end
    i = i + 1
  end
  return status
end

---@param cwd string?
---@param picker snacks.Picker
---@return table<string, string>?
function M.request_git_status(cwd, picker)
  if not cwd then
    return
  end

  local root = Snacks.git.get_root(cwd)
  if not root then
    return
  end

  picker_git_status[picker] = picker_git_status[picker] or {}
  local states = picker_git_status[picker]
  local state = states[root] or {}
  states[root] = state
  if state.status then
    return state.status
  end
  if state.pending then
    return
  end

  state.pending = true
  local stdout = assert(uv.new_pipe())
  local output = {}
  local exit_code ---@type number?
  local eof = false
  local handle ---@type uv.uv_process_t?

  local function finish()
    if exit_code == nil or not eof then
      return
    end
    local status = exit_code == 0 and parse_git_status(root, table.concat(output)) or {}
    vim.schedule(function()
      state.pending = false
      state.status = status
      if not picker.closed then
        picker.list:update({ force = true })
      end
    end)
  end

  ---@diagnostic disable-next-line: missing-fields
  handle = uv.spawn("git", {
    args = {
      "-c",
      "core.quotepath=false",
      "--no-pager",
      "--no-optional-locks",
      "status",
      "--porcelain=v1",
      "-uall",
      "--ignored=matching",
      "-z",
    },
    cwd = root,
    stdio = { nil, stdout, nil },
    hide = true,
  }, function(code)
    exit_code = code
    if handle then
      handle:close()
    end
    finish()
  end)

  if not handle then
    stdout:close()
    state.pending = false
    state.status = {}
    return
  end

  stdout:read_start(function(err, data)
    assert(not err, err)
    if data then
      output[#output + 1] = data
    else
      eof = true
      stdout:close()
      finish()
    end
  end)
  return
end

---@param item snacks.picker.Item
---@param picker snacks.Picker
---@return string?
function M.git_status(item, picker)
  local path = Snacks.picker.util.path(item)
  if not path then
    return
  end

  local root = Snacks.git.get_root(path)
  local status = M.request_git_status(root, picker)
  return status and status[svim.fs.normalize(path, { _fast = true, expand_env = false })]
end

---@param picker snacks.Picker
local function filename_first(picker)
  local file = picker.opts.formatters and picker.opts.formatters.file
  return (picker.opts.source == "files" or picker.opts.source == "smart")
    and file ~= nil
    and file.filename_first == true
end

---@type {cmd:string[], args:string[], enabled?:boolean, available?:boolean|string}[]
local commands = {
  {
    cmd = { "fd", "fdfind" },
    args = { "--type", "f", "--type", "l", "--color", "never", "-E", ".git" },
  },
  {
    cmd = { "rg" },
    args = { "--files", "--no-messages", "--color", "never", "-g", "!.git" },
  },
  {
    cmd = { "find" },
    args = { ".", "-type", "f", "-not", "-path", "*/.git/*" },
    enabled = vim.fn.has("win-32") == 0,
  },
}

---@param cmd? string
---@return string? cmd, string[]? args
function M.get_cmd(cmd)
  local checked = {} ---@type string[]
  for _, command in ipairs(commands) do
    if command.enabled ~= false and command.available ~= false and (not cmd or vim.tbl_contains(command.cmd, cmd)) then
      if command.available then
        assert(type(command.available) == "string", "available must be a string")
        return command.available, vim.deepcopy(command.args)
      end
      for _, c in ipairs(command.cmd) do
        table.insert(checked, c)
        if vim.fn.executable(c) == 1 then
          command.available = c
          return c, vim.deepcopy(command.args)
        end
      end
      command.available = false
    end
  end
  checked = #checked == 0 and cmd and { cmd } or checked
  checked = vim.tbl_map(function(c)
    return "`" .. c .. "`"
  end, checked)
  Snacks.notify.error("No supported finder found:\n- " .. table.concat(checked, "\n-"))
end

function M.get_fd()
  return M.get_cmd("fd")
end

---@param opts snacks.picker.files.Config
---@param filter snacks.picker.Filter
local function get_cmd(opts, filter)
  local cmd, args = M.get_cmd(opts.cmd)
  if not cmd or not args then
    return
  end
  local is_fd, is_fd_rg, is_find, is_rg = cmd == "fd" or cmd == "fdfind", cmd ~= "find", cmd == "find", cmd == "rg"

  -- exclude
  for _, e in ipairs(opts.exclude or {}) do
    if is_fd then
      vim.list_extend(args, { "-E", e })
    elseif is_rg then
      vim.list_extend(args, { "-g", "!" .. e })
    elseif is_find then
      table.insert(args, "-not")
      table.insert(args, "-path")
      table.insert(args, e)
    end
  end

  -- extensions
  local ft = opts.ft or {}
  ft = type(ft) == "string" and { ft } or ft
  ---@cast ft string[]
  for _, e in ipairs(ft) do
    if is_fd then
      table.insert(args, "-e")
      table.insert(args, e)
    elseif is_rg then
      table.insert(args, "-g")
      table.insert(args, "*." .. e)
    elseif is_find then
      table.insert(args, "-name")
      table.insert(args, "*." .. e)
    end
  end

  -- hidden
  if opts.hidden and is_fd_rg then
    table.insert(args, "--hidden")
  elseif not opts.hidden and is_find then
    vim.list_extend(args, { "-not", "-path", "*/.*" })
  end

  -- ignored
  if opts.ignored and is_fd_rg then
    args[#args + 1] = "--no-ignore"
  end

  -- follow
  if opts.follow then
    args[#args + 1] = "-L"
  end

  -- extra args
  vim.list_extend(args, opts.args or {})

  -- file glob
  ---@type string?
  local pattern, pargs = Snacks.picker.util.parse(filter.search)
  vim.list_extend(args, pargs)

  pattern = pattern ~= "" and pattern or nil
  if pattern then
    if is_fd then
      table.insert(args, pattern)
    elseif is_rg then
      table.insert(args, "--glob")
      table.insert(args, pattern)
    elseif is_find then
      table.insert(args, "-name")
      table.insert(args, pattern)
    end
  end

  -- dirs
  local dirs = opts.dirs or {}
  if opts.rtp then
    vim.list_extend(dirs, Snacks.picker.util.rtp())
  end
  if #dirs > 0 then
    dirs = vim.tbl_map(svim.fs.normalize, dirs) ---@type string[]
    if is_fd and not pattern then
      args[#args + 1] = "."
    end
    if is_find then
      table.remove(args, 1)
      for _, d in pairs(dirs) do
        table.insert(args, 1, d)
      end
    else
      vim.list_extend(args, dirs)
    end
  end

  return cmd, args
end

---@param opts snacks.picker.files.Config
---@type snacks.picker.finder
function M.files(opts, ctx)
  local cwd = not (opts.rtp or (opts.dirs and #opts.dirs > 0))
      and svim.fs.normalize(opts and opts.cwd or uv.cwd() or ".")
    or nil
  if filename_first(ctx.picker) then
    M.request_git_status(cwd or ctx:cwd(), ctx.picker)
  end
  local cmd, args = get_cmd(opts, ctx.filter)
  if not cmd then
    return function() end
  end
  if opts.debug.files then
    Snacks.notify(cmd .. " " .. table.concat(args or {}, " "))
  end
  return require("snacks.picker.source.proc").proc(
    ctx:opts({
      cmd = cmd,
      args = args,
      notify = not opts.live,
      ---@param item snacks.picker.finder.Item
      transform = function(item)
        item.cwd = cwd
        item.file = item.text
      end,
    }),
    ctx
  )
end

---@param opts snacks.picker.proc.Config
---@type snacks.picker.finder
function M.zoxide(opts, ctx)
  return require("snacks.picker.source.proc").proc(
    ctx:opts({
      cmd = "zoxide",
      args = { "query", "--list" },
      ---@param item snacks.picker.finder.Item
      transform = function(item)
        item.file = item.text
        item.dir = true
      end,
    }),
    ctx
  )
end

return M
