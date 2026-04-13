-- Static filetype→lang overrides: languages whose treesitter lang name differs
-- from their Neovim filetype name.  These are registered immediately so that
-- built-in filetype detection works even before the registry has loaded.
local filetypes = {
  angular = { 'htmlangular' },
  bash = { 'sh' },
  bibtex = { 'bib' },
  c_sharp = { 'cs', 'csharp' },
  commonlisp = { 'lisp' },
  cooklang = { 'cook' },
  devicetree = { 'dts' },
  diff = { 'gitdiff' },
  eex = { 'eelixir' },
  elixir = { 'ex' },
  embedded_template = { 'eruby' },
  erlang = { 'erl' },
  facility = { 'fsd' },
  faust = { 'dsp' },
  gdshader = { 'gdshaderinc' },
  git_config = { 'gitconfig' },
  git_rebase = { 'gitrebase' },
  glimmer = { 'handlebars', 'html.handlebars' },
  godot_resource = { 'gdresource' },
  haskell = { 'hs' },
  haskell_persistent = { 'haskellpersistent' },
  idris = { 'idris2' },
  ini = { 'confini', 'dosini' },
  janet_simple = { 'janet' },
  javascript = { 'javascriptreact', 'ecma', 'ecmascript', 'jsx', 'js' },
  json = { 'jsonc' },
  glimmer_javascript = { 'javascript.glimmer' },
  latex = { 'tex' },
  linkerscript = { 'ld' },
  m68k = { 'asm68k' },
  make = { 'automake' },
  markdown = { 'pandoc' },
  muttrc = { 'neomuttrc' },
  ocaml_interface = { 'ocamlinterface' },
  perl = { 'pl' },
  poe_filter = { 'poefilter' },
  powershell = { 'ps1' },
  properties = { 'jproperties' },
  python = { 'py', 'gyp' },
  qmljs = { 'qml' },
  runescript = { 'clientscript' },
  scala = { 'sbt' },
  slang = { 'shaderslang' },
  sqp = { 'mysqp' },
  ssh_config = { 'sshconfig' },
  starlark = { 'bzl' },
  surface = { 'sface' },
  systemverilog = { 'verilog' },
  t32 = { 'trace32' },
  tcl = { 'expect' },
  terraform = { 'terraform-vars' },
  textproto = { 'pbtxt' },
  tlaplus = { 'tla' },
  tsx = { 'typescriptreact', 'typescript.tsx' },
  typescript = { 'ts' },
  glimmer_typescript = { 'typescript.glimmer' },
  typst = { 'typ' },
  udev = { 'udevrules' },
  uxntal = { 'tal', 'uxn' },
  v = { 'vlang' },
  vhs = { 'tape' },
  xml = { 'xsd', 'xslt', 'svg' },
  xresources = { 'xdefaults' },
}

for lang, ft in pairs(filetypes) do
  vim.treesitter.language.register(lang, ft)
end

-- Additionally register any filetype mappings declared in registry entries.
-- Registry loading is asynchronous; mappings that duplicate the static table
-- above are harmless (register is idempotent).
-- Use pcall so that a missing registry plugin
-- does not prevent the static registrations above from taking effect.
local ok, registry = pcall(require, 'treesitter-registry')
if ok then
  registry.load(function(reg)
    if not reg then
      return
    end
    for lang, entry in pairs(reg) do
      if entry.filetypes and #entry.filetypes > 0 then
        vim.treesitter.language.register(lang, entry.filetypes)
      end
    end
  end)
end
