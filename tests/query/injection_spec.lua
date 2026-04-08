local config = require('nvim-treesitter.config')
local ts = vim.treesitter

--- Build a set of parser .so files that are actually present on disk.
---@return table<string, boolean>
local function installed_parsers()
  local parser_dir = config.get_install_dir('parser')
  local installed = {} ---@type table<string, boolean>
  for f in vim.fs.dir(parser_dir) do
    installed[vim.fn.fnamemodify(f, ':r')] = true
  end
  return installed
end

--- Collect the set of injected languages referenced by assertions in a file.
--- Useful for building an upfront "can we run these?" check.
---@param assertions table[]
---@return table<string, boolean>
local function referenced_languages(assertions)
  local langs = {} ---@type table<string, boolean>
  for _, a in ipairs(assertions) do
    local name = a.expected_capture_name:gsub('^!', '')
    langs[name] = true
  end
  return langs
end

local function check_assertions(file)
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(file)
  local ft = vim.bo[buf].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local assertions = vim.fn.json_decode(vim.fn.system({
    os.getenv('HLASSERT'),
    '-p',
    config.get_install_dir('parser') .. '/' .. lang .. '.so',
    '-s',
    file,
  }))

  if #assertions == 0 then
    return -- nothing to test (e.g. no assertion comments in file)
  end

  -- Determine which injected parsers are missing so we can skip those
  -- assertions rather than hard-fail.
  local have = installed_parsers()
  local need = referenced_languages(assertions)
  local missing = {} ---@type table<string, boolean>
  for dep_lang in pairs(need) do
    -- Some "languages" (regex, comment, printf, luap) are built-in to
    -- neovim or are virtual and have no .so.  Only flag real parsers.
    local ok = pcall(vim.treesitter.language.add, dep_lang)
    if not ok and not have[dep_lang] then
      missing[dep_lang] = true
    end
  end

  local parser = ts.get_parser(buf, lang)

  local top_level_root = parser:parse(true)[1]:root()

  local skipped = {} ---@type table<string, boolean>

  for _, assertion in ipairs(assertions) do
    local row = assertion.position.row
    local col = assertion.position.column

    local neg_assert = assertion.expected_capture_name:match('^!')
    assertion.expected_capture_name = neg_assert and assertion.expected_capture_name:sub(2)
      or assertion.expected_capture_name

    -- Skip positive assertions for languages whose parser is not installed.
    if not neg_assert and missing[assertion.expected_capture_name] then
      skipped[assertion.expected_capture_name] = true
    else
      local found = false
      parser:for_each_tree(function(tstree, tree)
        if not tstree then
          return
        end
        local root = tstree:root()
        if not ts.is_in_node_range(root, row, col) or root == top_level_root then
          return
        end
        if assertion.expected_capture_name == tree:lang() then
          found = true
        end
      end)
      if neg_assert then
        assert.False(
          found,
          'Error in '
            .. file
            .. ':'
            .. (row + 1)
            .. ':'
            .. (col + 1)
            .. ': expected "'
            .. assertion.expected_capture_name
            .. '" not to be injected here!'
        )
      else
        assert.True(
          found,
          'Error in '
            .. file
            .. ':'
            .. (row + 1)
            .. ':'
            .. (col + 1)
            .. ': expected "'
            .. assertion.expected_capture_name
            .. '" to be injected here!'
        )
      end
    end
  end

  if next(skipped) then
    pending(
      'Skipped assertions for missing injection parser(s): '
        .. table.concat(vim.tbl_keys(skipped), ', ')
    )
  end
end

describe('injections', function()
  local files = vim.fn.split(vim.fn.glob('tests/query/injections/**/*.*'))
  for _, file in ipairs(files) do
    it(file, function()
      check_assertions(file)
    end)
  end
end)
