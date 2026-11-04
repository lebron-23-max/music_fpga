#!/usr/bin/env python3
"""Build v56 1024-byte MSCORE v2 songs."""
import hashlib
import mido
import struct
import zlib
from pathlib import Path

ROOT = Path(r"D:\gaoyun_project\music_1")
ASSET = ROOT / "android_app" / "app" / "assets"
SRC = Path(r"C:\Users\30112\Documents\Codex\2026-11-03\wav-15s\outputs\音符谱")
TPQ = 48
BPM = 120
FS = 48828.125
END_TICK = 30 * TPQ


def midi_notes(path, end_sec=15.0):
    mf = mido.MidiFile(path)
    active = {}
    notes = []
    t = 0.0
    for msg in mf.play(meta_messages=False):
        t += msg.time
        key = (getattr(msg, 'channel', 0), getattr(msg, 'note', 0))
        if msg.type == 'note_on' and msg.velocity > 0:
            active.setdefault(key, []).append(t)
        elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
            if active.get(key):
                start = active[key].pop(0)
                if start < end_sec:
                    notes.append((start, min(t, end_sec), msg.note))
    return notes


def make_map(notes, substitutions=None):
    substitutions = substitutions or {}
    used = sorted({substitutions.get(n, n) for _, _, n in notes})
    if len(used) > 25:
        raise ValueError(f"unique notes {len(used)} > 25")
    fill = 0
    while len(used) < 25:
        if fill not in used:
            used.append(fill)
        fill += 1
    return sorted(used[:25]), substitutions


def assign_tracks(notes):
    free = [0.0] * 8
    assigned = []
    for onset, off, note in sorted(notes, key=lambda x: (x[0], -x[2])):
        slot = next((i for i, end in enumerate(free) if end <= onset + 1e-7), None)
        if slot is None:
            raise ValueError(f"more than 8 simultaneous notes at {onset:.4f}s")
        free[slot] = off
        assigned.append((onset, off, note, slot))
    return assigned


def make_v2(filename, timbre, notes, name, substitutions=None, bpm=BPM):
    note_map, subs = make_map(notes, substitutions)
    mapped = [(s, e, subs.get(n, n)) for s, e, n in notes]
    events = assign_tracks(mapped)
    ticks_per_sec = 2.0 * TPQ * bpm / 120.0
    packed = []
    for onset, off, midi, slot in events:
        start = min(END_TICK - 1, max(0, round(onset * ticks_per_sec)))
        duration = max(1, min(255, round((off - onset) * ticks_per_sec)))
        duration = min(duration, END_TICK - start)
        packed.append((start, duration, midi, slot))
    packed.append((END_TICK, 0, note_map[0], 0))
    packed.sort(key=lambda x: (x[0], x[3]))
    if len(packed) > 240:
        raise ValueError(f"{filename}: events={len(packed)} > 240")
    body = bytearray()
    prev = 0
    for start, duration, midi, slot in packed:
        delta = start - prev
        prev = start
        note = note_map.index(midi)
        b0 = delta & 0xFF
        b1 = ((delta >> 8) & 0x0F) | (timbre << 4) | ((note & 0x10) << 3)
        b2 = (note & 0x0F) | (slot << 4)
        body += bytes((b0, b1, b2, duration & 0xFF))
    tempo_step = round(bpm * TPQ * (1 << 24) / (60.0 * FS))
    header = bytearray(64)
    header[0:8] = b"MSCORE1\x00"
    header[8] = 1
    header[9] = 8
    header[10] = TPQ
    header[11] = 4
    struct.pack_into("<I", header, 12, tempo_step)
    struct.pack_into("<H", header, 16, len(packed))
    struct.pack_into("<H", header, 18, len(body))
    struct.pack_into("<I", header, 20, zlib.crc32(body) & 0xFFFFFFFF)
    for i, midi in enumerate(note_map):
        header[24 + i] = midi
    data = (bytes(header) + bytes(body)).ljust(1024, b"\x00")
    if len(data) != 1024:
        raise ValueError("score must be 1024 bytes")
    (ASSET / filename).write_bytes(data)
    print(f"{filename}: notes={len(events)} events={len(packed)} unique={len(set(n for _,_,n in notes))} "
          f"map={note_map} sha={hashlib.sha256(data).hexdigest()[:16]}")


make_v2("kikujiro_summer.msc", 0, midi_notes(SRC / "01_钢琴_菊次郎的夏天_音高音符.mid"), "KIKUJIRO")
make_v2("always_with_me.msc", 1, midi_notes(SRC / "02_八音盒_千与千寻_音高音符.mid"), "ALWAYS WITH ME")
make_v2("chun_jiao_yu_zhi_ming.msc", 2, midi_notes(SRC / "03_电钢琴_春娇与志明_音高音符.mid"), "CHUN JIAO", {42:40, 73:74, 87:88})

def ode_notes():
    seq = [4,4,5,7, 7,5,4,2, 0,0,2,4, 4,2,2,2, 4,4,5,7, 7,5,4,2, 0,0,2,4, 2,0,0,0]
    return [(i*0.5*120.0/128.0, (i+1)*0.5*120.0/128.0, 72+n) for i,n in enumerate(seq)]
make_v2("ode_to_joy.msc", 0, ode_notes(), "ODE TO JOY", bpm=128)
make_v2("canon_in_d.msc", 3, midi_notes(SRC / "04_弦乐_帕赫贝尔卡农_音高音符.mid"), "CANON IN D")