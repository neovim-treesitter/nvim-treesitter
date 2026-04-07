local M = {}

--- @param filename string
--- @return string
function M.read_file(filename)
  local file = io.open(filename, 'r')
  if not file then
    error('could not open file for reading: ' .. filename)
  end
  local r = file:read('*a')
  file:close()
  return r
end

--- @param filename string
--- @param content string
function M.write_file(filename, content)
  local file = io.open(filename, 'w')
  if not file then
    error('could not open file for writing: ' .. filename)
  end
  file:write(content)
  file:close()
end

return M
