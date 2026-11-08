#!/usr/bin/env python3
# Replay a terminal log (e.g. from `screen -L`) and print the final screen as plain text.
# Usage: tools/vt-render.py LOGFILE [COLS ROWS]   (default 80 24). Handles cursor moves, scroll regions,
# save/restore, erase, OSC/DCS strings and deferred wrap; colours are dropped. A test aid, not a terminal.
import sys,re
data=open(sys.argv[1],'rb').read().decode('utf-8','replace')
W=int(sys.argv[2]) if len(sys.argv)>2 else 80; H=int(sys.argv[3]) if len(sys.argv)>3 else 24
scr=[[' ']*W for _ in range(H)]
r=c=0; top=0; bot=H-1; saved=(0,0); pend=False
def scroll():
    global scr
    del scr[top]; scr.insert(bot,[' ']*W)
def lf():
    global r
    if r==bot: scroll()
    elif r<H-1: r+=1
i=0
while i<len(data):
    ch=data[i]
    if ch=='\x1b':
        if data[i+1:i+2]==']' or data[i+1:i+2]=='P' or data[i+1:i+2]=='_':
            j=i+2
            while j<len(data) and data[j]!='\x07' and not (data[j]=='\x1b' and data[j+1:j+2]=='\\'): j+=1
            i=j+(1 if j<len(data) and data[j]=='\x07' else 2); continue
        if data[i+1:i+2]=='7': saved=(r,c); i+=2; continue
        if data[i+1:i+2]=='8': r,c=saved; pend=False; i+=2; continue
        m=re.match(r'\x1b\[([0-9;?<>=:]*)([ -/]*)([@-~])',data[i:])
        if m:
            ps=m.group(1); cmd=m.group(3); nums=[int(x) for x in ps.split(';') if x.isdigit()]
            k=nums[0] if nums else 1
            pend=False
            if cmd=='A': r=max(top if r>=top else 0,r-k)
            elif cmd=='B': r=min(bot if r<=bot else H-1,r+k)
            elif cmd=='H': r=(nums[0]-1 if nums else 0); c=(nums[1]-1 if len(nums)>1 else 0); r=min(r,H-1)
            elif cmd=='G': c=k-1
            elif cmd=='r':
                if nums: top=nums[0]-1; bot=nums[1]-1
                else: top=0; bot=H-1
                r=c=0
            elif cmd=='C': c=min(W-1,c+k)
            elif cmd=='D': c=max(0,c-k)
            elif cmd=='X': scr[r][c:c+k]=[' ']*min(k,W-c)
            elif cmd=='K': scr[r]=scr[r][:c]+[' ']*(W-c) if (nums[0] if nums else 0)==0 else [' ']*W
            elif cmd=='J' and (nums[0] if nums else 0)==2:
                for y in range(H): scr[y]=[' ']*W
            elif cmd=='J':
                scr[r]=scr[r][:c]+[' ']*(W-c)
                for y in range(r+1,H): scr[y]=[' ']*W
            i+=len(m.group(0)); continue
        i+=1; continue
    if ch=='\n': lf(); pend=False
    elif ch=='\r': c=0; pend=False
    else:
        if pend: c=0; lf(); pend=False
        scr[r][c]=ch
        if c==W-1: pend=True
        else: c+=1
    i+=1
for l in scr: print(''.join(l).rstrip())
