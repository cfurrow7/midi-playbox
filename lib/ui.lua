-- ui.lua: Screen drawing and input handling for MIDI JUKEBOX
-- 5 pages: Now Playing, Track Setup, Drums, Queue, Library
-- Dynamic track count - supports however many channels are in the MIDI file
-- Mutes: hold K1 + E2 to select track, K1 + K3 to toggle mute (any page)

local UI = {}
UI.__index = UI

local TrackAssign = include("midi-playbox/lib/track_assign")

local PAGES = { "PLAY", "TRACKS", "DRUMS", "QUEUE", "LIBRARY" }
local KIT_NAMES = { "808", "707", "606", "DrumTraks" }
local DRUM_VOICE_NAMES = { "KICK", "SNRE", "CHH", "OHH", "CLAP", "LTOM", "HTOM", "CRSH" }

function UI.new(sequencer, queue, state)
  local self = setmetatable({}, UI)
  self.seq = sequencer
  self.queue = queue
  self.state = state

  self.page = 1
  self.k1_held = false
  self.mute_cursor = 1

  -- Track setup page state
  self.track_cursor = 1
  self.track_scroll = 0
  self.track_field = 1  -- 1=output (unified ch1-16/nb/drm/off), 2=octave

  -- Drums page state
  self.drum_cursor = 1
  self.drum_vol = 0.8
  self.filter_freq = 20000
  self.filter_res = 0.3
  self.random_amt = 0.0

  -- Library state
  self.lib_files = {}
  self.lib_scroll = 0
  self.lib_cursor = 1

  -- Queue state
  self.queue_cursor = 1
  self.queue_scroll = 0

  -- Note flash per track (by index)
  self.flash = {}
  self.drum_flash = { 0, 0, 0, 0, 0, 0, 0, 0 }

  -- Favorites
  self.favorites = {}  -- set of display names that are favorited
  self:load_favorites()

  -- Animation
  self.anim_t = 0
  self.pyramid_rot = 0

  -- Reactive energy (driven by note density)
  self.energy = 0          -- current smoothed energy 0-1
  self.energy_peak = 0     -- peak hold for size burst
  self.note_hits = 0       -- raw hit counter per frame

  return self
end

function UI:refresh_library(midi_dir)
  self.lib_files = {}
  self:scan_dir_recursive(midi_dir, midi_dir)
  table.sort(self.lib_files, function(a, b)
    return a.display < b.display
  end)
end

function UI:scan_dir_recursive(dir, base_dir)
  local entries = util.scandir(dir)
  if not entries then return end
  for _, entry in ipairs(entries) do
    if entry:match("/$") then
      local dirname = entry:sub(1, -2)
      self:scan_dir_recursive(dir .. "/" .. dirname, base_dir)
    elseif entry:match("%.mid$") or entry:match("%.midi$") or entry:match("%.MID$") then
      local full_path = dir .. "/" .. entry
      local rel = dir:sub(#base_dir + 2)
      local display = entry:match("(.+)%.[Mm][Ii][Dd][Ii]?$") or entry
      if rel and #rel > 0 then
        display = rel .. "/" .. display
      end
      table.insert(self.lib_files, { file = full_path, name = entry, display = display })
    end
  end
end

-- ===== FAVORITES =====

local FAVORITES_PATH = _path.data .. "midi-playbox/favorites.txt"

function UI:load_favorites()
  self.favorites = {}
  local f = io.open(FAVORITES_PATH, "r")
  if not f then return end
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
      self.favorites[line] = true
    end
  end
  f:close()
end

function UI:save_favorites()
  os.execute("mkdir -p " .. _path.data .. "midi-playbox")
  local f = io.open(FAVORITES_PATH, "w")
  if not f then return end
  for name, _ in pairs(self.favorites) do
    f:write(name .. "\n")
  end
  f:close()
end

function UI:toggle_favorite(display_name)
  if self.favorites[display_name] then
    self.favorites[display_name] = nil
  else
    self.favorites[display_name] = true
  end
  self:save_favorites()
end

function UI:is_favorite(display_name)
  return self.favorites[display_name] == true
end

function UI:note_flash(track_idx)
  self.flash[track_idx] = 4
  self.note_hits = self.note_hits + 1
end

function UI:drum_voice_flash(voice)
  if voice >= 0 and voice < 8 then
    self.drum_flash[voice + 1] = 4
  end
end

function UI:decay_flash()
  for k, v in pairs(self.flash) do
    if v > 0 then self.flash[k] = v - 1 end
  end
  for i = 1, 8 do
    if self.drum_flash[i] > 0 then self.drum_flash[i] = self.drum_flash[i] - 1 end
  end
  -- Energy smoothing: hits -> energy with fast attack, slow decay
  local target = math.min(1.0, self.note_hits * 0.15)
  if target > self.energy then
    self.energy = self.energy + (target - self.energy) * 0.6  -- fast attack
  else
    self.energy = self.energy * 0.92  -- slow decay
  end
  self.energy_peak = math.max(self.energy, self.energy_peak * 0.95)
  self.note_hits = 0

  -- Animation speed scales with energy
  self.anim_t = self.anim_t + 0.04 + self.energy * 0.2
  self.pyramid_rot = self.pyramid_rot + 0.015 + self.energy * 0.08
end

-- ===== EYE CANDY =====

-- Spinning 3D wireframe pyramid - size pulses with energy
function UI:draw_pyramid()
  local cx, cy = 118, 14
  local e = self.energy_peak
  local size = 5 + e * 4
  local r = self.pyramid_rot

  local ax, ay = cx, cy - size * 1.4

  local base = {}
  for i = 0, 3 do
    local angle = (i * math.pi / 2) + r
    local bx = math.cos(angle) * size
    local bz = math.sin(angle) * size
    base[i + 1] = { cx + bx, cy + bz * 0.4 }
  end

  screen.level(math.floor(2 + e * 6))
  for i = 1, 4 do
    local j = (i % 4) + 1
    screen.move(base[i][1], base[i][2])
    screen.line(base[j][1], base[j][2])
    screen.stroke()
    screen.move(base[i][1], base[i][2])
    screen.line(ax, ay)
    screen.stroke()
  end
end

-- Reactive Lissajous - size/speed/brightness driven by note energy
function UI:draw_lissajous()
  local cx, cy = 108, 14
  local e = self.energy
  local ep = self.energy_peak
  local t = self.anim_t

  -- Scale size with energy (4-14 range)
  local rx = 4 + ep * 10
  local ry = 3 + ep * 7

  -- More points when busy
  local points = 20 + math.floor(e * 40)

  -- Brightness pulses with energy
  local base_level = 1 + math.floor(e * 6)
  screen.level(math.min(15, base_level))

  -- Frequency ratios shift slightly with energy for variety
  local fx = 3 + e * 0.5
  local fy = 2 + e * 0.3

  for i = 0, points do
    local angle = (i / points) * math.pi * 2
    local x = cx + math.sin(angle * fx + t) * rx
    local y = cy + math.cos(angle * fy + t * 0.7) * ry
    screen.pixel(x, y)
    screen.fill()
  end

  -- Extra inner pattern when energy is high
  if e > 0.3 then
    screen.level(math.floor(e * 8))
    local irx = rx * 0.5
    local iry = ry * 0.5
    for i = 0, 15 do
      local angle = (i / 15) * math.pi * 2
      local x = cx + math.sin(angle * 5 + t * 1.3) * irx
      local y = cy + math.cos(angle * 3 + t * 0.9) * iry
      screen.pixel(x, y)
      screen.fill()
    end
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
  for i = 1, 5 do
    screen.level(i == self.page and 15 or 2)
    screen.rect(88 + (i - 1) * 5, 1, 3, 3)
    screen.fill()
  end

  -- Mute overlay when K1 held (not on queue/library pages - they use K1 combos)
  if self.k1_held and self.page ~= 4 and self.page ~= 5 then
    self:draw_mute_overlay()
    screen.update()
    return
  end

  if self.page == 1 then
    self:draw_play()
  elseif self.page == 2 then
    self:draw_tracks()
  elseif self.page == 3 then
    self:draw_drums()
  elseif self.page == 4 then
    self:draw_queue()
  elseif self.page == 5 then
    self:draw_library()
  end

  -- Eye candy
  self:draw_lissajous()
  self:draw_pyramid()

  screen.update()
end

function UI:draw_mute_overlay()
  local tc = self.seq:track_count()
  if tc == 0 then
    screen.level(4)
    screen.move(64, 35)
    screen.text_center("No tracks loaded")
    screen.update()
    return
  end

  screen.level(15)
  screen.move(64, 12)
  screen.text_center("MUTE SELECT")

  local visible = math.min(tc, 4)
  local scroll = math.max(0, self.mute_cursor - visible)

  for i = 1, visible do
    local idx = scroll + i
    if idx > tc then break end
    local track = self.seq.tracks[idx]
    local y = 14 + (i - 1) * 12
    local selected = (self.mute_cursor == idx)

    screen.level(selected and 15 or 5)
    screen.move(4, y + 8)
    local label = TrackAssign.role_label(track.role) .. " " .. track.name
    if #label > 16 then label = label:sub(1, 15) .. "." end
    screen.text(label)

    screen.level(track.mute and 15 or 3)
    screen.move(100, y + 8)
    screen.text(track.mute and "MUTED" or "on")

    if selected then
      screen.level(8)
      screen.rect(2, y, 124, 11)
      screen.stroke()
    end
  end

  screen.level(3)
  screen.move(64, 63)
  screen.text_center("E2:select  K3:toggle")
end

function UI:draw_play()
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
  screen.move(70, 28)
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

  -- Time + queue position
  screen.level(6)
  screen.move(0, 45)
  screen.text(format_time(self.seq.elapsed) .. " / " .. format_time(self.seq.duration))

  if self.queue:count() > 0 then
    screen.level(4)
    screen.move(90, 45)
    screen.text(self.queue.position .. "/" .. self.queue:count())
  end

  -- Track activity - show up to 8 tracks
  local tc = math.min(self.seq:track_count(), 8)
  if tc > 0 then
    local w = math.floor(124 / tc)
    for i = 1, tc do
      local track = self.seq.tracks[i]
      local x = (i - 1) * w
      local lit = self.flash[i] and self.flash[i] > 0

      -- Label
      screen.level(track.mute and 2 or (lit and 15 or 6))
      screen.move(x + 1, 55)
      screen.text(TrackAssign.role_label(track.role):sub(1, 1))

      -- Activity bar
      if track.mute then
        screen.level(1)
      elseif track.output == "off" then
        screen.level(0)
      else
        screen.level(lit and 12 or 2)
      end
      screen.rect(x, 57, w - 2, 4)
      screen.fill()
    end
  end
end

-- Unified output positions: 1-16 = MIDI ch, 17 = nb, 18 = DRM, 19 = OFF
local function track_to_out_pos(track)
  if track.output == "off" then return 19
  elseif track.output == "internal" then return 18
  elseif track.output == "nb" then return 17
  else return track.out_channels[1] or 1
  end
end

local function apply_out_pos(track, pos)
  if pos >= 1 and pos <= 16 then
    track.output = "midi"
    track.out_channels = {pos}
  elseif pos == 17 then
    track.output = "nb"
    track.out_channels = {0}
  elseif pos == 18 then
    track.output = "internal"
    track.out_channels = {0}
  else
    track.output = "off"
    track.out_channels = {0}
  end
end

function UI:draw_tracks()
  local tc = self.seq:track_count()
  if tc == 0 then
    screen.level(4)
    screen.move(64, 35)
    screen.text_center("No song loaded")
    return
  end

  -- Header
  screen.level(4)
  screen.move(0, 14)
  screen.text("ROLE  NAME       OUT    OCT")

  local visible = 4
  for i = 1, visible do
    local idx = self.track_scroll + i
    if idx > tc then break end

    local track = self.seq.tracks[idx]
    local y = 14 + i * 11
    local selected = (self.track_cursor == idx)
    local muted = track.mute

    -- Role
    screen.level(muted and 3 or (selected and 15 or 6))
    screen.move(0, y + 6)
    screen.text(TrackAssign.role_label(track.role))

    -- Name (truncated)
    screen.level(muted and 3 or (selected and 12 or 5))
    screen.move(22, y + 6)
    local name = track.name
    if #name > 8 then name = name:sub(1, 7) .. "." end
    screen.text(name)

    -- Output (unified: ch1-16, nb, DRM, OFF)
    screen.level(selected and self.track_field == 1 and 15 or 6)
    screen.move(72, y + 6)
    local pos = track_to_out_pos(track)
    local out_str
    if pos <= 16 then out_str = "ch" .. pos
    elseif pos == 17 then out_str = "nb"
    elseif pos == 18 then out_str = "DRM"
    else out_str = "OFF"
    end
    screen.text(out_str)

    -- Octave
    screen.level(selected and self.track_field == 2 and 15 or 6)
    screen.move(104, y + 6)
    if track.output ~= "internal" then
      local oct = track.octave or 0
      screen.text(oct >= 0 and "+" .. oct or tostring(oct))
    end

    -- Mute indicator
    if muted then
      screen.level(3)
      screen.move(120, y + 6)
      screen.text("M")
    end
  end

  -- Scroll indicator
  if tc > visible then
    screen.level(3)
    screen.move(125, 62)
    screen.text(self.track_scroll + 1 .. "-" .. math.min(self.track_scroll + visible, tc) .. "/" .. tc)
  end
end

function UI:draw_drums()
  -- Kit
  screen.level(self.drum_cursor == 1 and 15 or 6)
  screen.move(0, 14)
  screen.text("Kit: " .. KIT_NAMES[self.state.kit or 1])

  -- Volume
  screen.level(self.drum_cursor == 2 and 15 or 6)
  screen.move(0, 24)
  local vol_pct = math.floor((self.drum_vol or 0.8) * 100)
  screen.text("Vol:" .. vol_pct .. "%")

  -- LPF
  screen.level(self.drum_cursor == 3 and 15 or 6)
  screen.move(50, 24)
  local freq_display
  if self.filter_freq >= 20000 then
    freq_display = "OFF"
  elseif self.filter_freq >= 1000 then
    freq_display = string.format("%.1fk", self.filter_freq / 1000)
  else
    freq_display = string.format("%dHz", math.floor(self.filter_freq))
  end
  screen.text("LPF:" .. freq_display)

  -- Res
  screen.level(self.drum_cursor == 4 and 15 or 6)
  screen.move(0, 34)
  screen.text("Res:" .. string.format("%.1f", self.filter_res))

  -- Random
  screen.level(self.drum_cursor == 5 and 15 or 6)
  screen.move(50, 34)
  local rnd_pct = math.floor(self.random_amt * 100)
  screen.text("Rnd:" .. rnd_pct .. "%")

  screen.level(3)
  screen.move(0, 63)
  screen.text("K2:dice K3:keep")

  for i = 1, 8 do
    local x = ((i - 1) % 4) * 32
    local y = 38 + math.floor((i - 1) / 4) * 13

    screen.level(self.drum_flash[i] > 0 and 15 or 4)
    screen.move(x + 2, y + 10)
    screen.text(DRUM_VOICE_NAMES[i])

    screen.level(self.drum_flash[i] > 0 and 12 or 1)
    screen.rect(x, y + 12, 28, 2)
    screen.fill()
  end
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

  -- Help + save confirmation
  screen.level(3)
  screen.move(128, 62)
  if self._save_flash and self._save_flash > 0 then
    screen.text_right("SAVED!")
    self._save_flash = self._save_flash - 1
  else
    screen.text_right("K2:del K3:play K1+K3:save")
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

  local fav_count = 0
  for _ in pairs(self.favorites) do fav_count = fav_count + 1 end
  screen.level(8)
  screen.move(64, 6)
  local header = #self.lib_files .. " files"
  if fav_count > 0 then header = header .. " / " .. fav_count .. " fav" end
  screen.text_center(header)

  local visible = 5
  for i = 1, visible do
    local idx = self.lib_scroll + i
    if idx > #self.lib_files then break end

    local entry = self.lib_files[idx]
    local y = 8 + i * 10
    local is_selected = (idx == self.lib_cursor)

    if is_selected then
      screen.level(1)
      screen.rect(0, y - 6, 128, 10)
      screen.fill()
    end

    -- Star for favorites
    local star = self:is_favorite(entry.display) and "*" or " "
    screen.level(is_selected and 15 or 5)
    screen.move(2, y + 2)
    screen.text(star)
    screen.move(8, y + 2)
    local name = entry.display
    if #name > 20 then name = name:sub(1, 19) .. "." end
    screen.text(name)
  end

  screen.level(3)
  screen.move(128, 62)
  screen.text_right("K3:add K1+K3:fav K2:play")
end

-- ===== INPUT HANDLING =====

function UI:enc(n, d)
  if self.k1_held then
    if n == 2 then
      self.mute_cursor = util.clamp(self.mute_cursor + d, 1, math.max(1, self.seq:track_count()))
    end
    return
  end

  if n == 1 then
    self.page = util.clamp(self.page + d, 1, 5)
  elseif self.page == 1 then
    self:enc_play(n, d)
  elseif self.page == 2 then
    self:enc_tracks(n, d)
  elseif self.page == 3 then
    self:enc_drums(n, d)
  elseif self.page == 4 then
    self:enc_queue(n, d)
  elseif self.page == 5 then
    self:enc_library(n, d)
  end
end

function UI:enc_play(n, d)
  if n == 2 then
    local bpm = self.seq:get_bpm() + d
    self.seq:set_bpm(bpm)
  elseif n == 3 then
    if d > 0 and self.queue:has_next() then
      if self.state.on_next then self.state.on_next() end
    end
  end
end

function UI:enc_tracks(n, d)
  local tc = self.seq:track_count()
  if tc == 0 then return end

  if n == 2 then
    self.track_cursor = util.clamp(self.track_cursor + d, 1, tc)
    -- Auto-scroll
    if self.track_cursor > self.track_scroll + 4 then
      self.track_scroll = self.track_cursor - 4
    elseif self.track_cursor <= self.track_scroll then
      self.track_scroll = self.track_cursor - 1
    end
  elseif n == 3 then
    local track = self.seq.tracks[self.track_cursor]
    if not track then return end

    if self.track_field == 1 then
      -- Unified output: ch1-16, nb, DRM, OFF
      local pos = track_to_out_pos(track)
      pos = util.clamp(pos + d, 1, 19)
      apply_out_pos(track, pos)
    elseif self.track_field == 2 then
      -- Adjust octave
      if track.output ~= "internal" then
        track.octave = util.clamp((track.octave or 0) + d, -3, 3)
      end
    end
  end
end

function UI:enc_drums(n, d)
  if n == 2 then
    self.drum_cursor = util.clamp(self.drum_cursor + d, 1, 5)
  elseif n == 3 then
    if self.drum_cursor == 1 then
      self.state.kit = util.clamp((self.state.kit or 1) + d, 1, 4)
      engine.kit(self.state.kit - 1)
    elseif self.drum_cursor == 2 then
      self.drum_vol = util.clamp((self.drum_vol or 0.8) + d * 0.05, 0, 1)
      engine.amp(self.drum_vol)
    elseif self.drum_cursor == 3 then
      local freq = self.filter_freq
      if d > 0 then
        freq = math.min(20000, freq * 1.08)
      else
        freq = math.max(60, freq / 1.08)
      end
      self.filter_freq = freq
      engine.lpf(freq)
    elseif self.drum_cursor == 4 then
      self.filter_res = util.clamp(self.filter_res + d * 0.05, 0.1, 1.0)
      engine.res(self.filter_res)
    elseif self.drum_cursor == 5 then
      self.random_amt = util.clamp(self.random_amt + d * 0.02, 0, 1)
      engine.random_amt(self.random_amt)
    end
  end
end

function UI:enc_queue(n, d)
  if n == 2 then
    self.queue_cursor = util.clamp(self.queue_cursor + d, 1, math.max(1, self.queue:count()))
    if self.queue_cursor > self.queue_scroll + 5 then
      self.queue_scroll = self.queue_cursor - 5
    elseif self.queue_cursor <= self.queue_scroll then
      self.queue_scroll = self.queue_cursor - 1
    end
  elseif n == 3 then
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
  if n == 1 then
    self.k1_held = (z == 1)
    return
  end

  if z ~= 1 then return end

  -- K1 combos: queue and library handle their own, others get mute toggle
  if self.k1_held then
    if self.page == 4 then
      self:key_queue(n)
      return
    elseif self.page == 5 then
      self:key_library(n)
      return
    else
      if n == 3 then
        self.seq:toggle_mute(self.mute_cursor)
      end
      return
    end
  end

  if self.page == 1 then
    self:key_play(n)
  elseif self.page == 2 then
    self:key_tracks(n)
  elseif self.page == 3 then
    self:key_drums(n)
  elseif self.page == 4 then
    self:key_queue(n)
  elseif self.page == 5 then
    self:key_library(n)
  end
end

function UI:key_play(n)
  if n == 2 then
    if self.seq.playing then
      self.seq:stop()
    else
      self.seq:play()
    end
  elseif n == 3 then
    self.seq:restart()
  end
end

function UI:key_tracks(n)
  if n == 2 then
    -- Toggle field: output <-> octave
    self.track_field = (self.track_field == 1) and 2 or 1
  elseif n == 3 then
    -- Toggle mute for selected track
    self.seq:toggle_mute(self.track_cursor)
  end
end

function UI:key_drums(n)
  if n == 2 then
    engine.randomize()
  elseif n == 3 then
    engine.random_keep()
  end
end

function UI:key_queue(n)
  if n == 2 then
    -- K2: remove song from queue
    self.queue:remove(self.queue_cursor)
    self.queue_cursor = util.clamp(self.queue_cursor, 1, math.max(1, self.queue:count()))
  elseif n == 3 then
    if self.k1_held then
      -- K1+K3: save queue as playlist
      if self.queue:count() > 0 then
        local playlist_dir = _path.code .. "midi-playbox/playlists"
        os.execute("mkdir -p " .. playlist_dir)
        local filepath = playlist_dir .. "/saved.txt"
        if self.queue:save_playlist(filepath) then
          print("Queue saved to " .. filepath)
          self._save_flash = 30  -- show "SAVED!" for ~3 seconds
        end
      end
    else
      -- K3: play selected song
      self.queue.position = self.queue_cursor
      if self.state.on_load_current then
        self.state.on_load_current()
      end
    end
  end
end

function UI:key_library(n)
  if n == 2 then
    local entry = self.lib_files[self.lib_cursor]
    if entry and self.state.on_play_file then
      self.state.on_play_file(entry)
    end
  elseif n == 3 then
    local entry = self.lib_files[self.lib_cursor]
    if entry then
      if self.k1_held then
        -- K1+K3: toggle favorite
        self:toggle_favorite(entry.display)
      else
        -- K3: add to queue
        self.queue:add(entry.display, entry.file)
      end
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
