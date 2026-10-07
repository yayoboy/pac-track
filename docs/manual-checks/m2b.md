# M2b — manual checks

Build and open: `scripts/bundle.sh && open build/PacTrack.app`. Start from two PCs (10.0.0.1/24, 10.0.0.2/24) on a switch.

**Time modes**
- [ ] Toolbar ▸ *Simulation*: the clock stops and shows nanoseconds; *Passo* (or `.` with the canvas focused) runs one event: a row appears in *Eventi*, its PDU opens on the right, a coloured tag moves along the cable.
- [ ] In Simulation press ▶: events advance about twice a second at 1×, faster at higher speeds; ⏸ stops.
- [ ] Back to *Realtime*: the clock runs again; a ping shows ARP/ICMP tags flashing along the cables.

**Events and PDU**
- [ ] Toggle ARP/ICMP/UDP filters and pick a node: the list follows; the counter updates.
- [ ] Click an ICMP row: Ethernet II / IPv4 / ICMP headers with MACs, TTL, checksum, id/seq; groups collapse.
- [ ] Drag the divider between canvas and bottom panel, and between the list and the PDU inspector.
- [ ] Cmd+Z after a network change empties the event list (new network).

**Links and power**
- [ ] Select a cable: set Banda `10`, Ritardo `1000`, Perdita `50`, Coda `5`; the cable label shows `10 Mb/s`; ping shows losses and ~2 ms RTT. Type `abc`: red error under the field.
- [ ] Right-click a cable ▸ *Simula guasto*: dashed red; ping fails. ▸ *Ripristina*: ping works. Cmd+Z undoes each.
- [ ] Right-click PC1 ▸ *Spegni*: dimmed, red LED, Ping/Traceroute disabled; power button in the inspector turns it back on.
- [ ] Save, close, reopen: link values, faults and powered-off devices are as left.

**Copy, paste, palette**
- [ ] Select PC1, Cmd+C, Cmd+V twice: PC3, PC4 appear stepped below-right (56 pt, no overlap) with PC1's IP; Cmd+D duplicates the selection. Right-click empty canvas ▸ *Incolla*: the copy lands under the pointer.
- [ ] In a text field Cmd+C/V/X/A edit text, not devices.
- [ ] Type `rou` in the palette search: only Router remains; `zzz` shows "Nessun dispositivo".

**Loop warning**
- [ ] Two switches with two cables between them, a PC pinging any address: an orange banner warns of a possible L2 loop on the switches; the app stays responsive; ✕ closes it.

**M2a fixes**
- [ ] Pinch zoom keeps the point under the fingers fixed; two-finger scroll pans the canvas (not the inspector or panels).
- [ ] Type an IP + Return, then Cmd+Z right away: the network change is undone (the field is no longer focused).
- [ ] Right-click empty canvas ▸ *Aggiungi dispositivo* ▸ Router: R1 appears under where you right-clicked, also when the menu item lies over the canvas.
