#!/usr/bin/env python3
"""Verify v56 1024-byte v2 score assets against their source MIDI timing."""
import mido, struct, zlib, hashlib
from pathlib import Path

ROOT=Path(r"D:\gaoyun_project\music_1")
ASSET=ROOT/"android_app"/"app"/"assets"
SRC=Path(r"C:\Users\30112\Documents\Codex\2026-11-03\wav-15s\outputs\音符谱")
END_TICK=1440
SPECS={
 "kikujiro_summer.msc":(0,SRC/"01_钢琴_菊次郎的夏天_音高音符.mid",{}),
 "always_with_me.msc":(1,SRC/"02_八音盒_千与千寻_音高音符.mid",{}),
 "chun_jiao_yu_zhi_ming.msc":(2,SRC/"03_电钢琴_春娇与志明_音高音符.mid",{42:40,73:74,87:88}),
 "canon_in_d.msc":(3,SRC/"04_弦乐_帕赫贝尔卡农_音高音符.mid",{}),
}
errors=[]

def midi_notes(path):
 mf=mido.MidiFile(path); active={}; out=[]; t=0.0
 for msg in mf.play(meta_messages=False):
  t+=msg.time; k=(getattr(msg,'channel',0),getattr(msg,'note',0))
  if msg.type=='note_on' and msg.velocity>0:
   active.setdefault(k,[]).append(t)
  elif msg.type=='note_off' or (msg.type=='note_on' and msg.velocity==0):
   if active.get(k):
    st=active[k].pop(0)
    if st<15: out.append((st,min(t,15),msg.note))
 return out

def decode(path):
 b=path.read_bytes()
 if len(b)!=1024 or b[:8]!=b"MSCORE1\x00" or b[8]!=1 or not (b[11]&4): raise ValueError("not v2 1024 file")
 n=struct.unpack_from("<H",b,16)[0]; eb=struct.unpack_from("<H",b,18)[0]
 if eb!=4*n or 64+eb>1024: raise ValueError("event layout")
 if (zlib.crc32(b[64:64+eb])&0xffffffff)!=struct.unpack_from("<I",b,20)[0]: raise ValueError("body crc")
 mp=list(b[24:49]); ev=[]; p=64
 for _ in range(n):
  b0,b1,b2,b3=b[p:p+4]; p+=4
  delta=((b1&0x0f)<<8)|b0; timbre=(b1>>4)&3; note=((b1&0x80)>>3)|(b2&0x0f); track=b2>>4; dur=b3
  ev.append((delta,timbre,note,track,dur))
 return b,mp,ev

for name,(timbre,midi,subs) in SPECS.items():
 try:
  b,mp,ev=decode(ASSET/name); notes=midi_notes(midi); mapped=[(s,e,subs.get(n,n)) for s,e,n in notes]
  tick=0; got=[]
  for delta,tr,note,track,dur in ev:
   tick+=delta
   if dur: got.append((tick,tr,track,mp[note],dur))
  if ev[-1][4]!=0 or tick!=END_TICK: errors.append(f"{name}: end marker")
  if any(v!=timbre for _,v,_,_,_ in got): errors.append(f"{name}: timbre")
  exp=[]
  for s,e,n in mapped:
   st=max(0,min(END_TICK-1,round(s*96))); dd=max(1,min(255,round((e-s)*96))); dd=min(dd,END_TICK-st); exp.append((st,n,dd))
  ga=sorted((st,midi_note,dur) for st,_tr,_slot,midi_note,dur in got)
  ex=sorted((st,midi_note,dur) for st,midi_note,dur in exp)
  if ga!=ex:
   errors.append(f"{name}: note set mismatch")
   for a,bv in zip(ga,ex):
    if a!=bv: print(" first mismatch",name,a,bv); break
  tracks={i:0 for i in range(8)}
  for st,tr,slot,midi_note,dur in got:
   if st<tracks[slot]: errors.append(f"{name}: track overlap {slot}"); break
   tracks[slot]=st+dur
  print(name,"events",len(ev),"map_unique",len(set(mp)),"sha",hashlib.sha256(b).hexdigest().upper())
 except Exception as e: errors.append(f"{name}: {e}")

try:
 b,mp,ev=decode(ASSET/"ode_to_joy.msc")
 if len(ev)!=33 or ev[-1][4]!=0 or sum(x[0] for x in ev)!=END_TICK: errors.append("ode: layout")
 print("ode_to_joy.msc events",len(ev),"sha",hashlib.sha256(b).hexdigest().upper())
except Exception as e: errors.append(f"ode: {e}")

# Jingle is deliberately the untouched v52 legacy file.
j=(ASSET/"jingle_bells.msc").read_bytes()
if len(j)!=512 or hashlib.sha256(j).hexdigest().upper()!="02F9A6B3B53C521CF3B439F116B9470512E3DBEDD99FAAC2257EDEE466F173DB":
 errors.append("jingle: legacy hash")
if errors:
 print("V56_BUILTIN_SCORES_FAIL")
 for e in errors: print(" -",e)
 raise SystemExit(1)
print("V56_BUILTIN_SCORES_PASS five_v2_15s=1 jingle_legacy=1 ode_simple=1")