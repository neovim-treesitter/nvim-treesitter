local M = {}

function M.setup(...)
  require('nvim-treesitter.config').setup(...)
end

function M.get_available(...)
  return require('nvim-treesitter.config').get_available(...)
end

function M.get_installed(...)
  return require('nvim-treesitter.config').get_installed(...)
end

function M.install(...)
  return require('nvim-treesitter.install').install(...)
end

function M.uninstall(...)
  return require('nvim-treesitter.install').uninstall(...)
end

function M.update(...)
  return require('nvim-treesitter.install').update(...)
end

function M.status(...)
  return require('nvim-treesitter.install').status(...)
end

function M.indentexpr()
  return require('nvim-treesitter.indent').get_indent(vim.v.lnum)
end

--- Backwards-compatibility shim for user configs that call
--- require("nvim-treesitter").get_parser_configs().
--- Returns the registry's loaded table when available, otherwise {}.
function M.get_parser_configs()
  local registry = require('treesitter-registry')
  if registry.loaded and next(registry.loaded) then
    return registry.loaded
  end
  return {}
end

return M
