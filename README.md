# MIDI Playbox (MIDI Jukebox)

Dynamic MIDI song player for monome norns with built-in drum machine and AKAI MIDIMIX control. Loads standard MIDI files, auto-assigns tracks to roles, routes synth parts to hardware via MIDI and drums to an internal 808/707/606/DrumTraks engine.

## Requirements

- monome norns
- MIDI interface + hardware synths
- Optional: Akai MIDIMIX controller
- MIDI files in the shared `data/midi/` folder

## Install

From Maiden REPL:
```
;install https://github.com/cfurrow7/midi-playbox.git
```

Place `.mid` files in `~/dust/data/midi/` (shared folder accessible by all norns scripts).

## Channel Routing

Tracks are auto-detected by role (from track name or note range) and routed to fixed channels:

| Role | Channel(s) | Synth |
|------|-----------|-------|
| Bass | 2 | Mother 32 |
| Chord | 4 + 11 | OB-6 + Evolver |
| Lead | 10 + 3 | MS-101 + Pro 3 |
| FX | 4 + 11 | (same as chord) |
| Drum | 15 (internal) | Built-in drum engine |

When multiple tracks share a role, they split across channels round-robin:
- 1 chord track: layered to ch 4 + 11
- 2 chord tracks: first -> ch 4, second -> ch 11
- 3+ chord tracks: round-robin through 4, 11, 4...

## Pages

### PLAY (page 1)
Now playing display with track activity visualization.

- **E1**: switch page
- **K2**: play/stop
- **K3**: restart current song

### TRACKS (page 2)
Per-track settings: output channel, octave, output mode.

- **E2**: select track
- **E3**: adjust selected field
- **K2**: cycle field (output ch / octave / output mode)
- **K3**: cycle output mode (midi/internal)

### DRUMS (page 3)
Drum engine controls.

- **E2**: select parameter (kit, filter, resonance, random)
- **E3**: adjust value
- **K2**: randomize drum parameters
- **K3**: random keep (keep good randomization)

Drum kits: 808, 707, 606, DrumTraks

### QUEUE (page 4)
Song queue with playlist management.

- **E2**: select song
- **E3**: move song up/down (rearrange)
- **K2**: remove song from queue
- **K3**: play selected song
- **K1+K3**: save queue as playlist

Saved playlists go to `code/midi-playbox/playlists/saved.txt` and auto-load on next startup.

### LIBRARY (page 5)
Browse all MIDI files with favorites.

- **E2/E3**: scroll through files
- **K2**: play song immediately
- **K3**: add song to queue
- **K1+K3**: toggle favorite (star marker)

Favorites persist to `data/midi-playbox/favorites.txt`.

## MIDIMIX Controller Map

```
 KNOB ROW 1:  MIDI ch per track (1-16)
 KNOB ROW 2:  Program Change per track (1-7), drum LPF filter (8)
 KNOB ROW 3:  drum resonance (8)

 MUTE 1-8:    toggle track mute (LED on = unmuted)
 REC 1-8:     toggle all-channel broadcast

 FADERS 1-8:  track velocity
 MASTER:      BPM (20-300)

 BANK L/R:    prev/next song in queue
 SEND ALL:    PANIC (stop + all notes off)
```

## Muting

Hold **K1** on pages 1-3 to show the mute overlay. Use **E2** to select a track and **K3** to toggle mute. (Queue and Library pages use K1 for save/favorite instead.)

## Parameters

Available in norns PARAMS menu:
- MIDI Out Device
- MIDIMIX Device
- Drum Kit (808/707/606/DrumTraks)

## Credits

- v1.1 @clf
