# playOPXY

MIDI jukebox for OP-XY on monome norns. Forked from midi-playbox -- pure MIDI out, no internal drum engine. Auto-assigns MIDI tracks to roles and routes them to OP-XY channels.

## Requirements

- monome norns
- OP-XY connected via MIDI
- Optional: Akai MIDIMIX controller
- MIDI files in the shared `data/midi/` folder (same library as midi-playbox)

## Install

Place in `~/dust/code/playopxy/`. Uses the same shared MIDI folder as midi-playbox (`~/dust/data/midi/`).

## OP-XY Channel Routing

Tracks are auto-detected by role (from track name or note range) and routed to OP-XY channels:

| Role | Channel(s) | OP-XY Track |
|------|-----------|-------------|
| Bass | 2 | Bass |
| Chord | 4, 11 | Poly, Poly |
| Lead | 10 | Lead |
| FX | 3 | Bass/Lead |
| Drum | 3 | Bass/Lead (fallback) |

When multiple tracks share a role, they split across channels round-robin.

All channels are configurable via norns PARAMS menu.

## Pages

### PLAY (page 1)
Now playing display with track activity visualization.

- **E1**: switch page
- **E2**: adjust BPM
- **K2**: play/stop
- **K3**: restart current song

### TRACKS (page 2)
Per-track settings: output channel, octave.

- **E2**: select track
- **E3**: adjust selected field (ch1-16, nb voices, OFF)
- **K2**: cycle field (output / octave)
- **K3**: toggle mute

### QUEUE (page 3)
Song queue with playlist management.

- **E2**: select song
- **E3**: move song up/down
- **K2**: remove song from queue
- **K3**: play selected song
- **K1+K3**: save queue as playlist

### LIBRARY (page 4)
Browse all MIDI files with favorites.

- **E2/E3**: scroll through files
- **K2**: play song immediately
- **K3**: add song to queue
- **K1+K3**: toggle favorite

## MIDIMIX Controller Map

```
 KNOB ROW 1:  MIDI ch per track (1-7), unused (8)
 KNOB ROW 2:  Program Change per track (1-7), unused (8)

 MUTE 1-8:    toggle track mute (LED on = unmuted)
 REC 1-8:     toggle nb voice mode

 FADERS 1-8:  track velocity
 MASTER:      BPM (20-300)

 BANK L/R:    prev/next song in queue
 SEND ALL:    PANIC (stop + all notes off)
```

## Credits

- v1.0 @clf (forked from midi-playbox v1.3)
