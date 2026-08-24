---@module 'luassert'

local Format = require("snacks.picker.format")
local List = require("snacks.picker.core.list")
local defaults = require("snacks.picker.config.defaults").defaults

---@param source string
---@param filename_first boolean
---@param filename_width number
local function picker(source, filename_first, filename_width)
  local opts = vim.deepcopy(defaults)
  opts.source = source
  opts.formatters.file.filename_first = filename_first
  opts.icons.files.enabled = false
  return {
    opts = opts,
    list = { filename_width = filename_width },
    cwd = function()
      return "/tmp"
    end,
  }
end

---@param item snacks.picker.Item
---@param p snacks.Picker
---@return string
local function text(item, p)
  local line = Format.filename(item, p)
  line = Snacks.picker.highlight.resolve(line, 80)
  return Snacks.picker.highlight.to_text(line)
end

describe("file format", function()
  it("aligns filename-first paths by filename width", function()
    local p = picker("files", true, vim.api.nvim_strwidth("long_name.lua"))
    local short = text({ file = "/tmp/lua/a.lua" }, p)
    local long = text({ file = "/tmp/lua/long_name.lua" }, p)

    assert.are.equal(short:find("lua", 8, true), long:find("lua", 14, true))
  end)

  it("uses display width for unicode filenames", function()
    local p = picker("smart", true, vim.api.nvim_strwidth("long_name.lua"))
    local unicode = text({ file = "/tmp/source/文.lua" }, p)
    local long = text({ file = "/tmp/source/long_name.lua" }, p)

    local unicode_column = unicode:find("source", 1, true)
    local long_column = long:find("source", 1, true)
    assert.are.equal(
      vim.api.nvim_strwidth(unicode:sub(1, unicode_column - 1)),
      vim.api.nvim_strwidth(long:sub(1, long_column - 1))
    )
  end)

  it("does not pad a truncated filename to its raw width", function()
    local p = picker("files", true, 100)
    local filename = string.rep("x", 100) .. ".lua"
    local value = text({ file = "/tmp/source/" .. filename }, p)

    assert.is_true(vim.api.nvim_strwidth(value) < 100)
  end)

  it("does not measure filename width while adding items", function()
    local original = vim.api.nvim_strwidth
    vim.api.nvim_strwidth = function()
      error("filename width must be measured during render")
    end
    local ok, err = pcall(List.add, {
      items = {},
      picker = picker("files", true, 0),
      visible = {},
      state = { height = 0 },
      dirty = false,
    }, { file = "/tmp/a.lua" }, false)
    vim.api.nvim_strwidth = original

    assert.is_true(ok, err)
  end)

  it("shows git status before the file icon", function()
    local p = picker("smart", true, 0)
    local line = Format.file({ file = "/tmp/a.lua", status = " M" }, p)
    line = Snacks.picker.highlight.resolve(line, 80)
    local value, extmarks = Snacks.picker.highlight.to_text(line)

    assert.are.equal(" ○", extmarks[1].virt_text[1][1])
    assert.are.equal(4, value:find("a.lua", 1, true))
  end)

  it("only enables the special layout for files and smart", function()
    assert.is_true(Format.filename_first(picker("files", true, 0)))
    assert.is_true(Format.filename_first(picker("smart", true, 0)))
    assert.is_false(Format.filename_first(picker("recent", true, 0)))
    assert.is_false(Format.filename_first(picker("files", false, 0)))
  end)
end)
