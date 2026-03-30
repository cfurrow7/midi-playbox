-- grid_ui.lua: Monome Grid 128 (16x8) controller for playOPXY
--
-- LAYOUT:
--   Row 1:     Track mute toggles (1-8) | Transport: play stop restart next
--   Row 2:     Track activity LEDs (flashes on note)
--   Row 3:     Track output cycle (midi/off)
--   Row 4-8:   Song queue (up to 80 songs, 5 rows x 16 cols)
--
-- LED brightness levels:
--   0 = off, 4 = dim, 8 = medium, 12 = bright, 15 = max

local GridUI = {}
GridUI.__index = GridUI

local TrackAssign = include("playopxy/lib/track_assign")

function GridUI.new(sequencer, queue, state)
  local self = setmetatable({}, GridUI)

  self.seq = sequencer
  self.queue = queue
  self.state = state
  self.g = nil
  self.connected = false

  -- Track note flash (mirrors screen UI flash)
  self.flash = {}
  self.drum_flash = {0, 0, 0, 0, 0, 0, 0, 0}

  -- Song page offset (for queues > 48 songs)
  self.song_page = 0

  return self
end

function GridUI:connect()
  self.g = grid.connect()
  if self.g then
    self.connected = true
    self.g.key = function(x, y, z)
      self:handle_key(x, y, z)
    end
    print("Grid connected")
    self:refresh()
  end
end

function GridUI:note_flash(track_idx)
  self.flash[track_idx] = 4
end

function GridUI:drum_voice_flash(voice)
  if voice >= 0 and voice < 8 then
    self.drum_flash[voice + 1] = 4
  end
end

function GridUI:decay_flash()
  for k, v in pairs(self.flash) do
    if v > 0 then self.flash[k] = v - 1 end
  end
  for i = 1, 8 do
    if self.drum_flash[i] > 0 then self.drum_flash[i] = self.drum_flash[i] - 1 end
  end
end

-- ===== KEY HANDLING =====

function GridUI:handle_key(x, y, z)
  if z ~= 1 then return end  -- press only

  if y == 1 then
    self:handle_row_mute(x)
  elseif y == 3 then
    self:handle_row_output(x)
  elseif y >= 4 and y <= 8 then
    self:handle_row_songs(x, y)
  end
end

-- Row 1: Track mutes (1-8) + transport (13-16)
function GridUI:handle_row_mute(x)
  if x <= 8 then
    self.seq:toggle_mute(x)
  elseif x == 13 then
    -- Play/stop toggle
    if self.seq.playing then
      self.seq:stop()
    else
      self.seq:play()
    end
  elseif x == 14 then
    -- Stop
    self.seq:stop()
  elseif x == 15 then
    -- Restart
    self.seq:restart()
  elseif x == 16 then
    -- Next song
    if self.state.on_next then self.state.on_next() end
  end
end

-- Row 3: Cycle output mode per track
function GridUI:handle_row_output(x)
  if x <= 8 then
    self.seq:cycle_output(x)
  end
end

-- Rows 4-8: Song queue grid (press to jump + play)
function GridUI:handle_row_songs(x, y)
  local row_offset = y - 4  -- 0-4
  local song_idx = self.song_page + (row_offset * 16) + x
  if song_idx <= self.queue:count() then
    self.queue.position = song_idx
    if self.state.on_load_current then
      self.state.on_load_current()
    end
  end
end

-- ===== LED DRAWING =====

function GridUI:refresh()
  if not self.g or not self.connected then return end

  self.g:all(0)

  self:draw_row_mute()
  self:draw_row_activity()
  self:draw_row_output()
  self:draw_row_songs()

  self.g:refresh()
end

-- Row 1: Mute state + transport
function GridUI:draw_row_mute()
  local tc = self.seq:track_count()
  for x = 1, 8 do
    if x <= tc then
      local track = self.seq.tracks[x]
      if track.mute then
        self.g:led(x, 1, 2)   -- dim = muted
      else
        self.g:led(x, 1, 10)  -- bright = active
      end
    end
  end

  -- Transport: play stop restart next
  self.g:led(13, 1, self.seq.playing and 15 or 4)  -- play
  self.g:led(14, 1, 4)                              -- stop
  self.g:led(15, 1, 4)                              -- restart
  self.g:led(16, 1, self.queue:has_next() and 8 or 2) -- next
end

-- Row 2: Activity flash (note triggers)
function GridUI:draw_row_activity()
  local tc = self.seq:track_count()
  for x = 1, 8 do
    if x <= tc then
      local lit = self.flash[x] and self.flash[x] > 0
      local track = self.seq.tracks[x]
      if track.mute or track.output == "off" then
        self.g:led(x, 2, 0)
      elseif lit then
        self.g:led(x, 2, 15)
      else
        self.g:led(x, 2, 2)
      end
    end
  end

  -- Progress bar on row 2, cols 9-16
  if self.seq.duration > 0 then
    local progress = self.seq.elapsed / self.seq.duration
    local filled = math.floor(progress * 8)
    for x = 9, 16 do
      local col = x - 8
      self.g:led(x, 2, col <= filled and 8 or 1)
    end
  end
end

-- Row 3: Output mode per track
function GridUI:draw_row_output()
  local tc = self.seq:track_count()
  for x = 1, 8 do
    if x <= tc then
      local track = self.seq.tracks[x]
      if track.output == "midi" then
        self.g:led(x, 3, 8)   -- medium = MIDI
      elseif track.output == "nb" then
        self.g:led(x, 3, 12)  -- bright = nb voice
      else
        self.g:led(x, 3, 1)   -- barely = off
      end
    end
  end
end

-- Rows 4-8: Song queue grid
function GridUI:draw_row_songs()
  local count = self.queue:count()
  if count == 0 then return end

  for row = 0, 4 do
    for col = 1, 16 do
      local song_idx = self.song_page + (row * 16) + col
      if song_idx <= count then
        local is_current = (song_idx == self.queue.position)
        if is_current then
          self.g:led(col, 4 + row, 15)
        else
          self.g:led(col, 4 + row, 4)
        end
      end
    end
  end
end

return GridUI
