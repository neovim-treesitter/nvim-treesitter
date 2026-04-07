local function prepend_rtp(path)
  if path and path ~= '' then
    vim.opt.rtp:prepend(path)
  end
end

-- Test dependencies passed as env vars by the Makefile
prepend_rtp(os.getenv('PLENARY'))
prepend_rtp(os.getenv('PLENTEST'))

vim.o.rtp = vim.fn.stdpath('data') .. '/site,' .. vim.o.rtp
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
