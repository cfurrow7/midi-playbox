-- track_assign.lua: Auto-assign MIDI file channels to roles
-- Dynamic track count - creates a track per active channel
-- Ported from Play My Synths logic

local TrackAssign = {}

-- Role detection patterns (from PMS)
local role_patterns = {
  drum = { "drum", "perc", "kit", "beat", "cymbal", "snare", "kick", "hat" },
  bass = { "bass" },
  lead = { "lead", "melody", "solo", "vocal", "voice", "flute", "trumpet", "sax", "whistle" },
  chord = { "chord", "pad", "organ", "piano", "key", "string", "acoustic", "rhythm", "guitar", "harp" },
  fx = { "fx", "effect", "noise", "texture", "arp" },
}

-- GM drum note to voice mapping (8 voices)
-- 0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash
TrackAssign.gm_drum_map = {
  [35] = 0, [36] = 0,
  [38] = 1, [40] = 1, [37] = 1,
  [42] = 2, [44] = 2,
  [46] = 3,
  [39] = 4, [54] = 4,
  [41] = 5, [43] = 5, [45] = 5,
  [47] = 6, [48] = 6, [50] = 6,
  [49] = 7, [51] = 3, [52] = 7,
  [53] = 3, [55] = 7, [56] = 7, [57] = 7,
  [59] = 3,
}

for n = 58, 81 do
  if not TrackAssign.gm_drum_map[n] then
    TrackAssign.gm_drum_map[n] = 7
  end
end

-- Guess role from track name
local function guess_role(name)
  if not name then return nil end
  local lower = string.lower(name)
  for role, patterns in pairs(role_patterns) do
    for _, pat in ipairs(patterns) do
      if string.find(lower, pat, 1, true) then
        return role
      end
    end
  end
  return nil
end

-- Guess role from note range
local function guess_role_from_range(ch_info)
  if ch_info.max_note <= 55 then
    return "bass"
  elseif ch_info.min_note >= 60 then
    return "lead"
  else
    return "chord"
  end
end

-- Channel pools per role (tracks get spread across these)
-- If only 1 track of a role: gets all channels (layered)
-- If 2+ tracks: each gets one channel round-robin
-- These are the defaults; override with TrackAssign.set_channel()
local ROLE_CHANNEL_POOL = {
  bass  = {2},
  chord = {4},
  lead  = {10},
  fx    = {4},
}
local DRUM_CH = 15

-- Set primary channel for a role (replaces first entry in pool)
function TrackAssign.set_channel(role, ch)
  if role == "drum" then
    DRUM_CH = ch
  elseif ROLE_CHANNEL_POOL[role] then
    ROLE_CHANNEL_POOL[role][1] = ch
  end
end

-- Get current primary channel for a role
function TrackAssign.get_channel(role)
  if role == "drum" then return DRUM_CH end
  local pool = ROLE_CHANNEL_POOL[role]
  return pool and pool[1] or 1
end

-- Build track list from parsed MIDI channel data
-- Returns array of track objects sorted by note count (most first)
function TrackAssign.build_tracks(ch_data)
  local tracks = {}

  -- Create a track per active channel
  for ch, info in pairs(ch_data) do
    local role
    if ch == 10 then
      role = "drum"
    else
      role = guess_role(info.name)
      if not role then
        role = guess_role_from_range(info)
      end
    end

    table.insert(tracks, {
      source_ch = ch,
      name = info.name or ("Ch " .. ch),
      role = role or "chord",
      output = (role == "drum") and "internal" or "midi",
      out_channels = {},  -- assigned in second pass
      octave = 0,
      velocity_scale = 1.0,
      mute = false,
      note_count = info.note_count,
      min_note = info.min_note,
      max_note = info.max_note,
    })
  end

  -- Sort by note count (most notes first, like PMS)
  table.sort(tracks, function(a, b)
    if a.role == "drum" and b.role ~= "drum" then return false end
    if a.role ~= "drum" and b.role == "drum" then return true end
    return a.note_count > b.note_count
  end)

  -- Second pass: spread channels across tracks per role
  -- Count tracks per role
  local role_counts = {}
  for _, t in ipairs(tracks) do
    role_counts[t.role] = (role_counts[t.role] or 0) + 1
  end

  -- Assign channels round-robin
  local role_idx = {}  -- current index into channel pool per role
  for _, t in ipairs(tracks) do
    if t.role == "drum" then
      t.out_channels = {DRUM_CH}
    else
      local pool = ROLE_CHANNEL_POOL[t.role] or ROLE_CHANNEL_POOL.chord
      local count = role_counts[t.role] or 1

      if count == 1 then
        -- Solo track for this role: gets all channels (layered)
        t.out_channels = {table.unpack(pool)}
      else
        -- Multiple tracks: each gets one channel round-robin
        local idx = (role_idx[t.role] or 0)
        local ch = pool[(idx % #pool) + 1]
        t.out_channels = {ch}
        role_idx[t.role] = idx + 1
      end
    end
  end

  return tracks
end

-- Reassign out_channels on existing tracks using current channel pools
function TrackAssign.reassign_channels(tracks)
  if not tracks then return end
  local role_counts = {}
  for _, t in ipairs(tracks) do
    role_counts[t.role] = (role_counts[t.role] or 0) + 1
  end
  local role_idx = {}
  for _, t in ipairs(tracks) do
    -- Skip tracks that were manually set to all-16 broadcast
    if t.out_channels and #t.out_channels == 16 then
      -- leave as-is
    elseif t.role == "drum" then
      t.out_channels = {DRUM_CH}
    else
      local pool = ROLE_CHANNEL_POOL[t.role] or ROLE_CHANNEL_POOL.chord
      local count = role_counts[t.role] or 1
      if count == 1 then
        t.out_channels = {table.unpack(pool)}
      else
        local idx = (role_idx[t.role] or 0)
        local ch = pool[(idx % #pool) + 1]
        t.out_channels = {ch}
        role_idx[t.role] = idx + 1
      end
    end
  end
end

-- Map a GM drum note to a drum voice (0-7), or nil if not mapped
function TrackAssign.map_drum_note(note)
  return TrackAssign.gm_drum_map[note]
end

-- Short role label for display
function TrackAssign.role_label(role)
  local labels = {
    drum = "DRM",
    bass = "BAS",
    lead = "LED",
    chord = "CHD",
    fx = "FX",
  }
  return labels[role] or "???"
end

return TrackAssign
