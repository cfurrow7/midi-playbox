-- queue.lua: Song queue and playlist management

local Queue = {}
Queue.__index = Queue

function Queue.new()
  local self = setmetatable({}, Queue)
  self.songs = {}     -- { { name="Song", file="path.mid" }, ... }
  self.position = 1   -- current song index
  return self
end

function Queue:add(name, filepath)
  table.insert(self.songs, { name = name, file = filepath })
end

function Queue:remove(index)
  if index >= 1 and index <= #self.songs then
    table.remove(self.songs, index)
    -- Adjust position if needed
    if self.position > #self.songs then
      self.position = math.max(1, #self.songs)
    end
  end
end

function Queue:clear()
  self.songs = {}
  self.position = 1
end

function Queue:current()
  if #self.songs == 0 then return nil end
  if self.position > #self.songs then return nil end
  return self.songs[self.position]
end

function Queue:advance()
  if self.position < #self.songs then
    self.position = self.position + 1
    return self:current()
  end
  return nil  -- end of queue
end

function Queue:has_next()
  return self.position < #self.songs
end

function Queue:count()
  return #self.songs
end

function Queue:move_up(index)
  if index > 1 and index <= #self.songs then
    self.songs[index], self.songs[index - 1] = self.songs[index - 1], self.songs[index]
    if self.position == index then
      self.position = index - 1
    elseif self.position == index - 1 then
      self.position = index
    end
  end
end

function Queue:move_down(index)
  if index >= 1 and index < #self.songs then
    self.songs[index], self.songs[index + 1] = self.songs[index + 1], self.songs[index]
    if self.position == index then
      self.position = index + 1
    elseif self.position == index + 1 then
      self.position = index
    end
  end
end

-- Load playlist from text file (one filename per line)
function Queue:load_playlist(filepath, midi_dir)
  local f = io.open(filepath, "r")
  if not f then return false, "Cannot open playlist" end

  self:clear()
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line ~= "" and not line:match("^#") then  -- skip empty and comments
      local name = line:match("(.+)%.mid[i]?$") or line
      local full_path = midi_dir .. "/" .. line
      -- Add .mid if not present
      if not line:match("%.mid[i]?$") then
        full_path = full_path .. ".mid"
      end
      self:add(name, full_path)
    end
  end
  f:close()
  return true
end

-- Save current queue as a playlist file
function Queue:save_playlist(filepath)
  local f = io.open(filepath, "w")
  if not f then return false end
  for _, song in ipairs(self.songs) do
    -- Write the filename relative to midi dir
    local name = song.file:match(".*/(.+)$") or song.file
    f:write(name .. "\n")
  end
  f:close()
  return true
end

return Queue
