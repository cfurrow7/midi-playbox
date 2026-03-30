# playOPXY

MIDI jukebox for OP-XY on monome norns. Forked from midi-playbox. Pure MIDI out, no internal drum engine. Auto-assigns MIDI tracks to roles and routes them to OP-XY channels matching the default project layout.

## Requirements

- monome norns
- OP-XY connected via USB (USB-A from norns to USB-C on OP-XY)
- Optional: Akai MIDIMIX controller
- MIDI files in the shared `data/midi/` folder (same library as midi-playbox)

## Install

Place in `~/dust/code/playopxy/`. Uses the same shared MIDI folder as midi-playbox (`~/dust/data/midi/`).

## Connection

Connect a USB-A to USB-C cable from norns to the OP-XY. The OP-XY shows up as a class-compliant USB MIDI device. Set the correct device number in PARAMS > MIDI Out Device.

## OP-XY Channel Routing

Matches the OP-XY default project layout (track number = MIDI channel):

| Role | Channel(s) | OP-XY Default Track |
|------|-----------|---------------------|
| Drum | 1 (2) | Drums |
| Bass | 3 | Bass |
| FX | 4, 6 | Pluck, Soft pluck |
| Lead | 5 | Lead |
| Chord | 7, 8 | Strings, Pad |

When multiple tracks share a role, they split across channels round-robin:
- 1 chord track: layered to ch 7 + 8
- 2 chord tracks: first -> ch 7, second -> ch 8

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

## Muting

Hold **K1** on pages 1-2 to show the mute overlay. Use **E2** to select a track and **K3** to toggle mute.

## Credits

- v1.0 @clf (forked from midi-playbox v1.3)
