local function prepend_rtp(path)
  if path and path ~= '' then
    vim.opt.rtp:prepend(path)
  end
end

-- Test dependencies passed as env vars by the Makefile
prepend_rtp(os.getenv('PLENARY'))
prepend_rtp(os.getenv('PLENTEST'))

-- Ensure the nvim-treesitter repo itself is in rtp so that plugin/ and lua/
-- modules are resolvable when tests are run from the repo root.
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Use TS_INSTALL_DIR env var for an isolated, disposable parser install
-- directory that does not touch the user's real nvim data dir.
-- Falls back to <repo>/.test-deps/parsers when unset.
local ts_install_dir = os.getenv('TS_INSTALL_DIR')
  or vim.fs.joinpath(vim.fn.getcwd(), '.test-deps', 'parsers')
require('nvim-treesitter').setup({ install_dir = ts_install_dir })

vim.cmd.runtime({ 'plugin/query_predicates.lua', bang = true })
vim.cmd.runtime({ 'plugin/filetypes.lua', bang = true })

vim.filetype.add({
  extension = {
    conf = 'hocon',
    w = 'wing',
  },
})

vim.o.swapfile = false
vim.bo.swapfile = false

vim.api.nvim_create_autocmd('FileType', {
  callback = function(args)
    pcall(vim.treesitter.start)
    vim.bo[args.buf].indentexpr = 'v:lua.require"nvim-treesitter".indentexpr()'
  end,
})
