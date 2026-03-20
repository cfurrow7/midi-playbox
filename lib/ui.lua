-- ui.lua: Screen drawing and input handling for MIDI PLAYBOX
-- 4 pages: Now Playing, Track Setup, Queue, Library
-- 128x64 screen, 3 encoders (E1/E2/E3), 3 keys (K1/K2/K3)

local UI = {}
UI.__index = UI

local PAGES = { "PLAY", "TRACKS", "QUEUE", "LIBRARY" }
local KIT_NAMES = { "808", "707", "606", "DrumTraks" }

function UI.new(sequencer, queue, state)
  local self = setmetatable({}, UI)
  self.seq = sequencer
  self.queue = queue
  self.state = state  -- shared state table

  self.page = 1
  self.cursor = 1         -- per-page cursor position
  self.scroll = 0         -- scroll offset for lists

  -- Track setup page state
  self.track_cursor = 1   -- 1=bass, 2=chords, 3=lead, 4=drum kit
  self.track_field = 1    -- 1=out channel / kit, 2=octave

  -- Library state
  self.lib_files = {}
  self.lib_scroll = 0
  self.lib_cursor = 1

  -- Queue state
  self.queue_cursor = 1
  self.queue_scroll = 0

  -- Note flash (for visual feedback)
  self.flash = { bass = 0, chords = 0, lead = 0, drum = 0 }

  return self
end

function UI:refresh_library(midi_dir)
  self.lib_files = {}
  local files = util.scandir(midi_dir)
  if files then
    for _, f in ipairs(files) do
      if f:match("%.mid[i]?$") then
        table.insert(self.lib_files, f)
      end
    end
  end
  table.sort(self.lib_files)
end

function UI:note_flash(track)
  self.flash[track] = 4  -- frames to flash
end

function UI:decay_flash()
  for k, v in pairs(self.flash) do
    if v > 0 then self.flash[k] = v - 1 end
  end
end

-- ===== DRAWING =====

function UI:draw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- Page header
  screen.level(3)
  screen.move(0, 6)
  screen.text(PAGES[self.page])

  -- Page indicator dots
  for i = 1, 4 do
    screen.level(i == self.page and 15 or 2)
    screen.rect(108 + (i - 1) * 5, 1, 3, 3)
    screen.fill()
  end

  if self.page == 1 then
    self:draw_play()
  elseif self.page == 2 then
    self:draw_tracks()
  elseif self.page == 3 then
    self:draw_queue()
  elseif self.page == 4 then
    self:draw_library()
  end

  screen.update()
end

function UI:draw_play()
  -- Song name
  local song = self.queue:current()
  screen.level(15)
  screen.move(0, 18)
  if song then
    local name = song.name
    if #name > 21 then name = name:sub(1, 20) .. "." end
    screen.text(name)
  else
    screen.text("No song loaded")
  end

  -- BPM
  screen.level(10)
  screen.move(0, 28)
  local bpm = self.seq:get_bpm()
  local bpm_str = string.format("BPM: %d", bpm)
  if self.seq.bpm_override then bpm_str = bpm_str .. "*" end
  screen.text(bpm_str)

  -- Play state
  screen.level(15)
  screen.move(80, 28)
  screen.text(self.seq.playing and "> PLAY" or "  STOP")

  -- Progress bar
  local progress = 0
  if self.seq.duration > 0 then
    progress = self.seq.elapsed / self.seq.duration
  end
  screen.level(2)
  screen.rect(0, 33, 128, 4)
  screen.fill()
  screen.level(12)
  screen.rect(0, 33, math.floor(128 * progress), 4)
  screen.fill()

  -- Time
  screen.level(6)
  screen.move(0, 45)
  screen.text(format_time(self.seq.elapsed) .. " / " .. format_time(self.seq.duration))

  -- Track activity indicators
  local roles = { "bass", "chords", "lead", "drum" }
  local labels = { "B", "C", "L", "D" }
  for i, role in ipairs(roles) do
    local x = (i - 1) * 32
    screen.level(self.flash[role] > 0 and 15 or 3)
    screen.move(x + 4, 56)
    screen.text(labels[i])
    -- Activity bar
    screen.level(self.flash[role] > 0 and 12 or 1)
    screen.rect(x, 58, 28, 4)
    screen.fill()
  end

  -- Queue position
  if self.queue:count() > 0 then
    screen.level(4)
    screen.move(90, 45)
    screen.text(self.queue.position .. "/" .. self.queue:count())
  end
end

function UI:draw_tracks()
  local roles = { "bass", "chords", "lead" }
  local info = self.seq:get_track_info()

  for i, role in ipairs(roles) do
    local y = 10 + (i - 1) * 14
    local selected = (self.track_cursor == i)

    -- Role name
    screen.level(selected and 15 or 5)
    screen.move(0, y + 6)
    screen.text(string.upper(role:sub(1, 1)) .. role:sub(2))

    -- Source channel
    screen.level(selected and 10 or 4)
    screen.move(42, y + 6)
    local src = info[role].ch and ("src:" .. info[role].ch) or "---"
    screen.text(src)

    -- Output channel (editable)
    screen.level(selected and self.track_field == 1 and 15 or 6)
    screen.move(72, y + 6)
    screen.text("ch:" .. (self.seq.out_channels[role] or "?"))

    -- Octave
    screen.level(selected and self.track_field == 2 and 15 or 6)
    screen.move(102, y + 6)
    local oct = self.seq.octave[role] or 0
    screen.text(oct >= 0 and "+" .. oct or tostring(oct))
  end

  -- Drum kit row
  local y = 10 + 3 * 14
  local selected = (self.track_cursor == 4)
  screen.level(selected and 15 or 5)
  screen.move(0, y + 6)
  screen.text("Drum")

  screen.level(selected and 10 or 4)
  screen.move(42, y + 6)
  local drum_info = info.drum
  local src = drum_info.ch and ("src:" .. drum_info.ch) or "---"
  screen.text(src)

  screen.level(selected and 15 or 6)
  screen.move(72, y + 6)
  screen.text("kit:" .. KIT_NAMES[self.state.kit or 1])
end

function UI:draw_queue()
  screen.level(8)
  screen.move(64, 6)
  screen.text_center(self.queue:count() .. " songs")

  if self.queue:count() == 0 then
    screen.level(4)
    screen.move(64, 35)
    screen.text_center("Add songs from Library")
    return
  end

  local visible = 5
  for i = 1, visible do
    local idx = self.queue_scroll + i
    if idx > self.queue:count() then break end

    local song = self.queue.songs[idx]
    local y = 8 + i * 10
    local is_current = (idx == self.queue.position)
    local is_selected = (idx == self.queue_cursor)

    -- Highlight current and selected
    if is_selected then
      screen.level(1)
      screen.rect(0, y - 6, 128, 10)
      screen.fill()
    end

    screen.level(is_current and 15 or (is_selected and 12 or 5))
    screen.move(2, y + 2)
    local prefix = is_current and "> " or "  "
    local name = song.name
    if #name > 20 then name = name:sub(1, 19) .. "." end
    screen.text(prefix .. name)
  end
end

function UI:draw_library()
  if #self.lib_files == 0 then
    screen.level(4)
    screen.move(64, 35)
    screen.text_center("No MIDI files found")
    screen.move(64, 47)
    screen.text_center("Add .mid to midi/ folder")
    return
  end

  screen.level(8)
  screen.move(64, 6)
  screen.text_center(#self.lib_files .. " files")

  local visible = 5
  for i = 1, visible do
    local idx = self.lib_scroll + i
    if idx > #self.lib_files then break end

    local fname = self.lib_files[idx]
    local y = 8 + i * 10
    local is_selected = (idx == self.lib_cursor)

    if is_selected then
      screen.level(1)
      screen.rect(0, y - 6, 128, 10)
      screen.fill()
    end

    screen.level(is_selected and 15 or 5)
    screen.move(2, y + 2)
    local name = fname:match("(.+)%.mid[i]?$") or fname
    if #name > 22 then name = name:sub(1, 21) .. "." end
    screen.text(name)
  end

  -- Hint
  screen.level(3)
  screen.move(128, 62)
  screen.text_right("K3:add K2:play")
end

-- ===== INPUT HANDLING =====

function UI:enc(n, d)
  if n == 1 then
    -- Page navigation
    self.page = util.clamp(self.page + d, 1, 4)
  elseif self.page == 1 then
    self:enc_play(n, d)
  elseif self.page == 2 then
    self:enc_tracks(n, d)
  elseif self.page == 3 then
    self:enc_queue(n, d)
  elseif self.page == 4 then
    self:enc_library(n, d)
  end
end

function UI:enc_play(n, d)
  if n == 2 then
    -- BPM adjust
    local bpm = self.seq:get_bpm() + d
    self.seq:set_bpm(bpm)
  elseif n == 3 then
    -- Scrub through queue
    if d > 0 and self.queue:has_next() then
      -- Skip to next song (handled by main script)
      if self.state.on_next then self.state.on_next() end
    end
  end
end

function UI:enc_tracks(n, d)
  if n == 2 then
    -- Navigate rows
    self.track_cursor = util.clamp(self.track_cursor + d, 1, 4)
  elseif n == 3 then
    if self.track_cursor <= 3 then
      -- Edit field value
      local role = ({"bass", "chords", "lead"})[self.track_cursor]
      if self.track_field == 1 then
        -- Change output MIDI channel
        local ch = self.seq.out_channels[role] + d
        self.seq.out_channels[role] = util.clamp(ch, 1, 16)
      elseif self.track_field == 2 then
        -- Change octave
        local oct = (self.seq.octave[role] or 0) + d
        self.seq.octave[role] = util.clamp(oct, -3, 3)
      end
    else
      -- Drum kit selection
      self.state.kit = util.clamp((self.state.kit or 1) + d, 1, 4)
      engine.kit(self.state.kit - 1)  -- 0-indexed
    end
  end
end

function UI:enc_queue(n, d)
  if n == 2 then
    self.queue_cursor = util.clamp(self.queue_cursor + d, 1, math.max(1, self.queue:count()))
    -- Auto-scroll
    if self.queue_cursor > self.queue_scroll + 5 then
      self.queue_scroll = self.queue_cursor - 5
    elseif self.queue_cursor <= self.queue_scroll then
      self.queue_scroll = self.queue_cursor - 1
    end
  elseif n == 3 then
    -- Reorder
    if d > 0 then
      self.queue:move_down(self.queue_cursor)
      self.queue_cursor = util.clamp(self.queue_cursor + 1, 1, self.queue:count())
    else
      self.queue:move_up(self.queue_cursor)
      self.queue_cursor = util.clamp(self.queue_cursor - 1, 1, self.queue:count())
    end
  end
end

function UI:enc_library(n, d)
  if n == 2 or n == 3 then
    self.lib_cursor = util.clamp(self.lib_cursor + d, 1, math.max(1, #self.lib_files))
    if self.lib_cursor > self.lib_scroll + 5 then
      self.lib_scroll = self.lib_cursor - 5
    elseif self.lib_cursor <= self.lib_scroll then
      self.lib_scroll = self.lib_cursor - 1
    end
  end
end

function UI:key(n, z)
  if z ~= 1 then return end  -- only on press

  if self.page == 1 then
    self:key_play(n)
  elseif self.page == 2 then
    self:key_tracks(n)
  elseif self.page == 3 then
    self:key_queue(n)
  elseif self.page == 4 then
    self:key_library(n)
  end
end

function UI:key_play(n)
  if n == 2 then
    -- Play/Stop toggle
    if self.seq.playing then
      self.seq:stop()
    else
      self.seq:play()
    end
  elseif n == 3 then
    -- Restart
    self.seq:restart()
  end
end

function UI:key_tracks(n)
  if n == 2 then
    -- Toggle field (out channel vs octave) for synth tracks
    if self.track_cursor <= 3 then
      self.track_field = self.track_field == 1 and 2 or 1
    end
  elseif n == 3 then
    -- Cycle source channel for current track
    local roles = { "bass", "chords", "lead", "drum" }
    local role = roles[self.track_cursor]
    local available = self.seq:get_available_channels()
    if #available > 0 then
      local current = self.seq.assignment and self.seq.assignment[role] and self.seq.assignment[role].ch
      local next_idx = 1
      for i, ch in ipairs(available) do
        if ch == current then
          next_idx = (i % #available) + 1
          break
        end
      end
      self.seq:set_source_channel(role, available[next_idx])
    end
  end
end

function UI:key_queue(n)
  if n == 2 then
    -- Remove selected song from queue
    self.queue:remove(self.queue_cursor)
    self.queue_cursor = util.clamp(self.queue_cursor, 1, math.max(1, self.queue:count()))
  elseif n == 3 then
    -- Jump to selected song and play
    self.queue.position = self.queue_cursor
    if self.state.on_load_current then
      self.state.on_load_current()
    end
  end
end

function UI:key_library(n)
  if n == 2 then
    -- Load and play immediately
    local file = self.lib_files[self.lib_cursor]
    if file and self.state.on_play_file then
      self.state.on_play_file(file)
    end
  elseif n == 3 then
    -- Add to queue
    local file = self.lib_files[self.lib_cursor]
    if file and self.state.midi_dir then
      local name = file:match("(.+)%.mid[i]?$") or file
      self.queue:add(name, self.state.midi_dir .. "/" .. file)
    end
  end
end

-- ===== HELPERS =====

function format_time(seconds)
  if not seconds or seconds < 0 then return "0:00" end
  local m = math.floor(seconds / 60)
  local s = math.floor(seconds % 60)
  return string.format("%d:%02d", m, s)
end

return UI
