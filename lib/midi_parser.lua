-- midi_parser.lua: Parse Standard MIDI Files (format 0 and 1)
-- Returns a structured table of tracks with timed events

local MidiParser = {}

-- Read bytes from string at position
local function read_byte(data, pos)
  return string.byte(data, pos), pos + 1
end

local function read_bytes(data, pos, n)
  local val = 0
  for i = 0, n - 1 do
    val = val * 256 + string.byte(data, pos + i)
  end
  return val, pos + n
end

local function read_string(data, pos, n)
  return string.sub(data, pos, pos + n - 1), pos + n
end

-- Variable-length quantity (MIDI delta time encoding)
local function read_vlq(data, pos)
  local val = 0
  local byte
  for _ = 1, 4 do
    byte = string.byte(data, pos)
    pos = pos + 1
    val = val * 128 + (byte % 128)
    if byte < 128 then break end
  end
  return val, pos
end

-- Parse a single track chunk
local function parse_track(data, pos, track_end)
  local events = {}
  local running_status = 0
  local abs_tick = 0
  local track_name = nil

  while pos < track_end do
    -- Delta time
    local delta
    delta, pos = read_vlq(data, pos)
    abs_tick = abs_tick + delta

    -- Status byte
    local status = string.byte(data, pos)

    -- Running status: if high bit not set, reuse last status
    if status < 128 then
      status = running_status
    else
      pos = pos + 1
      running_status = status
    end

    local event_type = math.floor(status / 16)
    local channel = status % 16

    if event_type == 0x9 then
      -- Note On
      local note, vel
      note, pos = read_byte(data, pos)
      vel, pos = read_byte(data, pos)
      table.insert(events, {
        tick = abs_tick,
        type = vel > 0 and "note_on" or "note_off",
        channel = channel + 1,  -- 1-indexed
        note = note,
        velocity = vel
      })

    elseif event_type == 0x8 then
      -- Note Off
      local note, vel
      note, pos = read_byte(data, pos)
      vel, pos = read_byte(data, pos)
      table.insert(events, {
        tick = abs_tick,
        type = "note_off",
        channel = channel + 1,
        note = note,
        velocity = vel
      })

    elseif event_type == 0xB then
      -- Control Change (skip 2 bytes)
      pos = pos + 2

    elseif event_type == 0xC then
      -- Program Change (skip 1 byte)
      pos = pos + 1

    elseif event_type == 0xD then
      -- Channel Pressure (skip 1 byte)
      pos = pos + 1

    elseif event_type == 0xE then
      -- Pitch Bend (skip 2 bytes)
      pos = pos + 2

    elseif event_type == 0xA then
      -- Poly Aftertouch (skip 2 bytes)
      pos = pos + 2

    elseif status == 0xFF then
      -- Meta event
      local meta_type
      meta_type, pos = read_byte(data, pos)
      local length
      length, pos = read_vlq(data, pos)

      if meta_type == 0x03 then
        -- Track name
        track_name, pos = read_string(data, pos, length)
      elseif meta_type == 0x51 then
        -- Tempo (microseconds per beat)
        local uspb = read_bytes(data, pos, 3)
        pos = pos + length
        table.insert(events, {
          tick = abs_tick,
          type = "tempo",
          uspb = uspb,
          bpm = math.floor(60000000 / uspb + 0.5)
        })
      elseif meta_type == 0x2F then
        -- End of track
        pos = pos + length
        break
      else
        pos = pos + length
      end

    elseif status == 0xF0 or status == 0xF7 then
      -- SysEx (skip)
      local length
      length, pos = read_vlq(data, pos)
      pos = pos + length

    else
      -- Unknown, try to skip
      break
    end
  end

  return events, track_name
end

-- Main parse function
function MidiParser.parse(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil, "Cannot open file: " .. filepath end

  local data = f:read("*all")
  f:close()

  if #data < 14 then return nil, "File too small" end

  -- Header chunk
  local header_id = string.sub(data, 1, 4)
  if header_id ~= "MThd" then return nil, "Not a MIDI file" end

  local header_len = read_bytes(data, 5, 4)
  local format = read_bytes(data, 9, 2)
  local num_tracks = read_bytes(data, 11, 2)
  local ppqn = read_bytes(data, 13, 2)

  -- Handle SMPTE timing (rare, just bail)
  if ppqn >= 0x8000 then return nil, "SMPTE timing not supported" end

  local result = {
    format = format,
    ppqn = ppqn,
    tracks = {},
    channels = {},  -- channel info summary
    bpm = 120       -- default
  }

  local pos = 9 + header_len

  -- Parse track chunks
  for i = 1, num_tracks do
    if pos + 8 > #data then break end

    local chunk_id = string.sub(data, pos, pos + 3)
    local chunk_len = read_bytes(data, pos + 4, 4)
    pos = pos + 8

    if chunk_id == "MTrk" then
      local track_end = pos + chunk_len
      local events, track_name = parse_track(data, pos, track_end)

      table.insert(result.tracks, {
        name = track_name,
        events = events
      })

      -- Extract first tempo
      for _, ev in ipairs(events) do
        if ev.type == "tempo" then
          result.bpm = ev.bpm
          break
        end
      end

      pos = track_end
    else
      pos = pos + chunk_len
    end
  end

  -- Build channel summary (note counts, note ranges)
  local ch_info = {}
  for ch = 1, 16 do
    ch_info[ch] = { note_count = 0, min_note = 127, max_note = 0, name = nil }
  end

  for _, track in ipairs(result.tracks) do
    for _, ev in ipairs(track.events) do
      if ev.type == "note_on" and ev.velocity > 0 then
        local ch = ev.channel
        ch_info[ch].note_count = ch_info[ch].note_count + 1
        if ev.note < ch_info[ch].min_note then ch_info[ch].min_note = ev.note end
        if ev.note > ch_info[ch].max_note then ch_info[ch].max_note = ev.note end
        -- Inherit track name
        if track.name and not ch_info[ch].name then
          ch_info[ch].name = track.name
        end
      end
    end
  end

  -- Only include channels that have notes
  for ch = 1, 16 do
    if ch_info[ch].note_count > 0 then
      result.channels[ch] = ch_info[ch]
    end
  end

  return result
end

-- Merge all tracks into a single sorted event list with absolute times in seconds
function MidiParser.to_timeline(parsed, bpm_override)
  local all_events = {}
  local tempo_map = {}

  -- Collect tempo changes from all tracks
  for _, track in ipairs(parsed.tracks) do
    for _, ev in ipairs(track.events) do
      if ev.type == "tempo" then
        table.insert(tempo_map, { tick = ev.tick, uspb = ev.uspb })
      end
    end
  end

  -- Sort tempo map
  table.sort(tempo_map, function(a, b) return a.tick < b.tick end)

  -- Default tempo if none found
  if #tempo_map == 0 then
    table.insert(tempo_map, { tick = 0, uspb = 500000 }) -- 120 BPM
  end

  -- Convert ticks to seconds using tempo map
  local function tick_to_sec(tick)
    if bpm_override then
      return tick / parsed.ppqn * (60 / bpm_override)
    end

    local sec = 0
    local last_tick = 0
    local last_uspb = tempo_map[1].uspb

    for _, t in ipairs(tempo_map) do
      if t.tick >= tick then break end
      if t.tick > last_tick then
        sec = sec + (t.tick - last_tick) / parsed.ppqn * (last_uspb / 1000000)
        last_tick = t.tick
      end
      last_uspb = t.uspb
    end

    sec = sec + (tick - last_tick) / parsed.ppqn * (last_uspb / 1000000)
    return sec
  end

  -- Collect all note events
  for _, track in ipairs(parsed.tracks) do
    for _, ev in ipairs(track.events) do
      if ev.type == "note_on" or ev.type == "note_off" then
        table.insert(all_events, {
          time = tick_to_sec(ev.tick),
          tick = ev.tick,
          type = ev.type,
          channel = ev.channel,
          note = ev.note,
          velocity = ev.velocity
        })
      end
    end
  end

  -- Sort by time, then by type (note_off before note_on at same time)
  table.sort(all_events, function(a, b)
    if a.time == b.time then
      if a.type ~= b.type then
        return a.type == "note_off"
      end
      return a.note < b.note
    end
    return a.time < b.time
  end)

  -- Calculate total duration
  local duration = 0
  if #all_events > 0 then
    duration = all_events[#all_events].time + 0.5  -- small tail
  end

  return all_events, duration
end

-- Filter and quantize a timeline to reduce CPU load
-- quantize_div: 0=off, 4=1/4, 8=1/8, 16=1/16, 32=1/32
-- min_vel: drop note_on events below this velocity (0=off)
-- min_dur: drop notes shorter than this in seconds (0=off)
function MidiParser.filter_timeline(events, bpm, quantize_div, min_vel, min_dur)
  if (not quantize_div or quantize_div == 0) and
     (not min_vel or min_vel == 0) and
     (not min_dur or min_dur == 0) then
    return events  -- nothing to do
  end

  local beat_sec = 60 / (bpm or 120)
  local grid = quantize_div and quantize_div > 0 and (beat_sec / (quantize_div / 4)) or 0
  min_vel = min_vel or 0
  min_dur = min_dur or 0

  -- First pass: build note_on -> note_off pairs to compute durations
  -- Key: channel..":"..note -> {time, index}
  local note_starts = {}
  local short_notes = {}  -- set of indices to remove

  if min_dur > 0 then
    for i, ev in ipairs(events) do
      local key = ev.channel .. ":" .. ev.note
      if ev.type == "note_on" and ev.velocity > 0 then
        note_starts[key] = { time = ev.time, idx = i }
      elseif ev.type == "note_off" or (ev.type == "note_on" and ev.velocity == 0) then
        local start = note_starts[key]
        if start then
          local dur = ev.time - start.time
          if dur < min_dur then
            short_notes[start.idx] = true
            short_notes[i] = true
          end
          note_starts[key] = nil
        end
      end
    end
  end

  -- Second pass: filter and quantize
  local filtered = {}
  local before = #events
  for i, ev in ipairs(events) do
    local keep = true

    -- Drop short notes
    if short_notes[i] then keep = false end

    -- Drop quiet notes
    if keep and ev.type == "note_on" and ev.velocity > 0 and min_vel > 0 then
      if ev.velocity < min_vel then keep = false end
    end

    if keep then
      -- Quantize time to grid
      if grid > 0 then
        ev.time = math.floor(ev.time / grid + 0.5) * grid
      end
      table.insert(filtered, ev)
    end
  end

  -- Re-sort after quantize (times may have shifted)
  if grid > 0 then
    table.sort(filtered, function(a, b)
      if a.time == b.time then
        if a.type ~= b.type then
          return a.type == "note_off"
        end
        return a.note < b.note
      end
      return a.time < b.time
    end)
  end

  local after = #filtered
  if before ~= after then
    print("MIDI filter: " .. before .. " -> " .. after .. " events (removed " .. (before - after) .. ")")
  end

  return filtered
end

return MidiParser
