// Engine_DrumBox: 8-voice synthesized drum machine for MIDI PLAYBOX
// Kits: 808, 707, 606, DrumTraks (all synthesis, no samples needed)
// Global LPF filter on drum output

Engine_DrumBox : CroneEngine {
    var <kitParams;
    var <masterAmp;
    var <filterBus;
    var <filterSynth;
    var <lpfFreq;
    var <randomAmount;
    var <randomOffsets;  // per-voice per-param offsets

    alloc {
        masterAmp = 0.8;
        lpfFreq = 20000;
        randomAmount = 0.0;
        randomOffsets = Array.fill(8, { Dictionary[\freq -> 0, \decay -> 0, \sweep -> 0, \noiseAmt -> 0] });

        // Audio bus for drum output -> filter
        filterBus = Bus.audio(context.server, 2);

        // ---- SynthDefs ----

        // Global filter (sits on output, processes all drums)
        SynthDef(\drumbox_filter, { |in, out=0, lpf=20000, res=0.3|
            var sig = In.ar(in, 2);
            sig = RLPF.ar(sig, lpf.clip(20, 20000), res.clip(0.1, 1.0));
            Out.ar(out, sig);
        }).add;

        // Kick: sine with pitch sweep + click
        SynthDef(\drumbox_kick, { |out=0, freq=45, sweep=4, decay=0.8, click=0.02, amp=0.5, pan=0|
            var clickEnv = EnvGen.kr(Env.perc(0.001, click), doneAction: 0);
            var pitchEnv = EnvGen.kr(Env.perc(0.001, 0.07));
            var body = SinOsc.ar(freq + (freq * sweep * pitchEnv));
            var env = EnvGen.kr(Env.perc(0.001, decay, curve: -6), doneAction: 2);
            var clickSig = WhiteNoise.ar * clickEnv * 0.3;
            var sig = (body + clickSig) * env * amp;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Snare: noise + tone
        SynthDef(\drumbox_snare, { |out=0, freq=180, noiseAmt=0.7, decay=0.2, snap=0.01, amp=0.5, pan=0|
            var toneEnv = EnvGen.kr(Env.perc(0.001, decay * 0.5, curve: -8), doneAction: 0);
            var noiseEnv = EnvGen.kr(Env.perc(snap, decay, curve: -4), doneAction: 2);
            var tone = SinOsc.ar(freq) * toneEnv * (1 - noiseAmt);
            var noise = BPF.ar(WhiteNoise.ar, freq * 4, 2) * noiseEnv * noiseAmt;
            var sig = (tone + noise) * amp;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Closed hi-hat: bandpass noise, short
        SynthDef(\drumbox_chh, { |out=0, freq=8000, decay=0.05, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, decay, curve: -8), doneAction: 2);
            var sig = BPF.ar(WhiteNoise.ar, freq, 0.3) * env * amp * 2;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Open hi-hat: bandpass noise, longer
        SynthDef(\drumbox_ohh, { |out=0, freq=8000, decay=0.3, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, decay, curve: -4), doneAction: 2);
            var sig = BPF.ar(WhiteNoise.ar, freq, 0.3) * env * amp * 2;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Clap: layered noise bursts
        SynthDef(\drumbox_clap, { |out=0, freq=1200, decay=0.15, spread=0.01, amp=0.5, pan=0|
            var env1 = EnvGen.kr(Env.perc(0.001, spread));
            var env2 = EnvGen.kr(Env.perc(0.001, spread), delay: spread);
            var env3 = EnvGen.kr(Env.perc(0.001, decay), delay: spread * 2, doneAction: 2);
            var noise = BPF.ar(WhiteNoise.ar, freq, 0.5);
            var sig = noise * (env1 + env2 + env3) * amp * 0.5;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Tom: sine with pitch sweep
        SynthDef(\drumbox_tom, { |out=0, freq=100, sweep=2, decay=0.3, amp=0.5, pan=0|
            var pitchEnv = EnvGen.kr(Env.perc(0.001, 0.05));
            var body = SinOsc.ar(freq + (freq * sweep * pitchEnv));
            var env = EnvGen.kr(Env.perc(0.001, decay, curve: -6), doneAction: 2);
            var sig = body * env * amp;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // Crash/Ride: metallic noise
        SynthDef(\drumbox_cymbal, { |out=0, freq=6000, decay=1.5, ring=0.3, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, decay, curve: -3), doneAction: 2);
            var noise = BPF.ar(WhiteNoise.ar, freq, 0.1);
            var ring1 = SinOsc.ar(freq * 1.37) * 0.1;
            var ring2 = SinOsc.ar(freq * 2.42) * 0.05;
            var sig = (noise + ring1 + ring2) * env * amp;
            Out.ar(out, Pan2.ar(sig, pan));
        }).add;

        // ---- Kit parameter definitions ----
        // Each kit: array of 8 voice specs [synthdef, params]
        // Voices: 0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash

        kitParams = Dictionary.new;

        // 808: deep, boomy, long decays
        kitParams[\kit808] = [
            [\drumbox_kick,   (\freq: 42,  \sweep: 5,   \decay: 0.9,  \click: 0.01, \pan: 0)],
            [\drumbox_snare,  (\freq: 160, \noiseAmt: 0.6, \decay: 0.25, \snap: 0.01, \pan: 0)],
            [\drumbox_chh,    (\freq: 7500, \decay: 0.04, \pan: 0.1)],
            [\drumbox_ohh,    (\freq: 7500, \decay: 0.35, \pan: 0.1)],
            [\drumbox_clap,   (\freq: 1100, \decay: 0.18, \spread: 0.012, \pan: 0)],
            [\drumbox_tom,    (\freq: 80,  \sweep: 2.5, \decay: 0.35, \pan: -0.3)],
            [\drumbox_tom,    (\freq: 160, \sweep: 2,   \decay: 0.25, \pan: 0.3)],
            [\drumbox_cymbal, (\freq: 5500, \decay: 1.8, \ring: 0.3,  \pan: 0.2)]
        ];

        // 707: tighter, punchier, more acoustic
        kitParams[\kit707] = [
            [\drumbox_kick,   (\freq: 55,  \sweep: 3,   \decay: 0.5,  \click: 0.02, \pan: 0)],
            [\drumbox_snare,  (\freq: 200, \noiseAmt: 0.75, \decay: 0.18, \snap: 0.008, \pan: 0)],
            [\drumbox_chh,    (\freq: 9000, \decay: 0.03, \pan: 0.1)],
            [\drumbox_ohh,    (\freq: 9000, \decay: 0.25, \pan: 0.1)],
            [\drumbox_clap,   (\freq: 1300, \decay: 0.12, \spread: 0.008, \pan: 0)],
            [\drumbox_tom,    (\freq: 95,  \sweep: 1.8, \decay: 0.25, \pan: -0.3)],
            [\drumbox_tom,    (\freq: 180, \sweep: 1.5, \decay: 0.2,  \pan: 0.3)],
            [\drumbox_cymbal, (\freq: 7000, \decay: 1.2, \ring: 0.2,  \pan: 0.2)]
        ];

        // 606: thin, tight, electronic
        kitParams[\kit606] = [
            [\drumbox_kick,   (\freq: 50,  \sweep: 3.5, \decay: 0.35, \click: 0.015, \pan: 0)],
            [\drumbox_snare,  (\freq: 220, \noiseAmt: 0.8, \decay: 0.12, \snap: 0.005, \pan: 0)],
            [\drumbox_chh,    (\freq: 10000, \decay: 0.02, \pan: 0.1)],
            [\drumbox_ohh,    (\freq: 10000, \decay: 0.2, \pan: 0.1)],
            [\drumbox_clap,   (\freq: 1400, \decay: 0.1, \spread: 0.006, \pan: 0)],
            [\drumbox_tom,    (\freq: 110, \sweep: 2, \decay: 0.18, \pan: -0.3)],
            [\drumbox_tom,    (\freq: 200, \sweep: 1.5, \decay: 0.15, \pan: 0.3)],
            [\drumbox_cymbal, (\freq: 8000, \decay: 0.8, \ring: 0.15, \pan: 0.2)]
        ];

        // DrumTraks: punchy, 12-bit grit
        kitParams[\kitDrumTraks] = [
            [\drumbox_kick,   (\freq: 48,  \sweep: 4,   \decay: 0.6,  \click: 0.025, \pan: 0)],
            [\drumbox_snare,  (\freq: 190, \noiseAmt: 0.65, \decay: 0.22, \snap: 0.012, \pan: 0)],
            [\drumbox_chh,    (\freq: 8500, \decay: 0.035, \pan: 0.1)],
            [\drumbox_ohh,    (\freq: 8500, \decay: 0.28, \pan: 0.1)],
            [\drumbox_clap,   (\freq: 1200, \decay: 0.14, \spread: 0.01, \pan: 0)],
            [\drumbox_tom,    (\freq: 90,  \sweep: 2.2, \decay: 0.3,  \pan: -0.3)],
            [\drumbox_tom,    (\freq: 170, \sweep: 1.8, \decay: 0.22, \pan: 0.3)],
            [\drumbox_cymbal, (\freq: 6000, \decay: 1.4, \ring: 0.25, \pan: 0.2)]
        ];

        // Set current kit to 808 by default
        kitParams[\current] = kitParams[\kit808];

        // Start filter synth after a short delay to ensure SynthDefs are ready
        context.server.sync;
        filterSynth = Synth(\drumbox_filter, [\in, filterBus, \out, 0, \lpf, lpfFreq], addAction: \addToTail);

        // ---- Commands ----

        // Trigger a drum voice (0-7) with velocity (0.0-1.0)
        this.addCommand(\trig_kit, "if", { |msg|
            var voice = msg[1].asInteger;
            var vel = msg[2].asFloat;
            var currentKit = kitParams[\current];

            if (voice >= 0 && (voice < 8) && currentKit.notNil, {
                var spec = currentKit[voice];
                var synthName = spec[0];
                var params = spec[1].copy;
                var offsets = randomOffsets[voice];

                // Apply random offsets scaled by randomAmount
                if (randomAmount > 0, {
                    if (params[\freq].notNil, {
                        var baseFreq = params[\freq];
                        params[\freq] = (baseFreq * (1 + (offsets[\freq] * randomAmount))).clip(20, 15000);
                    });
                    if (params[\decay].notNil, {
                        var baseDec = params[\decay];
                        params[\decay] = (baseDec * (1 + (offsets[\decay] * randomAmount * 0.5))).clip(0.01, 3);
                    });
                    if (params[\sweep].notNil, {
                        var baseSweep = params[\sweep];
                        params[\sweep] = (baseSweep + (offsets[\sweep] * randomAmount * 3)).clip(0.5, 10);
                    });
                    if (params[\noiseAmt].notNil, {
                        var baseNoise = params[\noiseAmt];
                        params[\noiseAmt] = (baseNoise + (offsets[\noiseAmt] * randomAmount * 0.3)).clip(0, 1);
                    });
                });

                params[\amp] = vel * masterAmp;
                params[\out] = filterBus;
                Synth(synthName, params.asPairs, addAction: \addToHead);
            });
        });

        // Switch drum kit (0=808, 1=707, 2=606, 3=DrumTraks)
        this.addCommand(\kit, "i", { |msg|
            var kitIndex = msg[1].asInteger.clip(0, 3);
            var kitNames = [\kit808, \kit707, \kit606, \kitDrumTraks];
            kitParams[\current] = kitParams[kitNames[kitIndex]];
        });

        // Master amplitude (0.0-1.0)
        this.addCommand(\amp, "f", { |msg|
            masterAmp = msg[1].asFloat.clip(0, 1);
        });

        // LPF cutoff frequency (20-20000 Hz)
        this.addCommand(\lpf, "f", { |msg|
            lpfFreq = msg[1].asFloat.clip(20, 20000);
            if (filterSynth.notNil, {
                filterSynth.set(\lpf, lpfFreq);
            });
        });

        // Filter resonance (0.1-1.0, lower = more resonant)
        this.addCommand(\res, "f", { |msg|
            if (filterSynth.notNil, {
                filterSynth.set(\res, msg[1].asFloat.clip(0.1, 1.0));
            });
        });

        // Randomize: generate new random offsets for all voices
        this.addCommand(\randomize, "", { |msg|
            randomOffsets = Array.fill(8, {
                Dictionary[
                    \freq -> 1.0.rand2,      // -1 to +1
                    \decay -> 1.0.rand2,
                    \sweep -> 1.0.rand2,
                    \noiseAmt -> 1.0.rand2
                ]
            });
        });

        // Random amount (0.0 = no effect, 1.0 = full random)
        this.addCommand(\random_amt, "f", { |msg|
            randomAmount = msg[1].asFloat.clip(0, 1);
        });

        // Keep: bake current randomization into the kit params (new baseline)
        this.addCommand(\random_keep, "", { |msg|
            var currentKit = kitParams[\current];
            if (currentKit.notNil && (randomAmount > 0), {
                8.do { |voice|
                    var spec = currentKit[voice];
                    var params = spec[1];
                    var offsets = randomOffsets[voice];

                    if (params[\freq].notNil, {
                        params[\freq] = (params[\freq] * (1 + (offsets[\freq] * randomAmount))).clip(20, 15000);
                    });
                    if (params[\decay].notNil, {
                        params[\decay] = (params[\decay] * (1 + (offsets[\decay] * randomAmount * 0.5))).clip(0.01, 3);
                    });
                    if (params[\sweep].notNil, {
                        var baseSweep = params[\sweep];
                        params[\sweep] = (baseSweep + (offsets[\sweep] * randomAmount * 3)).clip(0.5, 10);
                    });
                    if (params[\noiseAmt].notNil, {
                        var baseNoise = params[\noiseAmt];
                        params[\noiseAmt] = (baseNoise + (offsets[\noiseAmt] * randomAmount * 0.3)).clip(0, 1);
                    });
                };
                // Reset offsets to zero since they're now baked in
                randomOffsets = Array.fill(8, {
                    Dictionary[\freq -> 0, \decay -> 0, \sweep -> 0, \noiseAmt -> 0]
                });
            });
        });
    }

    free {
        if (filterSynth.notNil, { filterSynth.free; });
        if (filterBus.notNil, { filterBus.free; });
    }
}
