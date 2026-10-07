# M2a — manual checks (no Xcode UI tests yet)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`

- [ ] File ▸ Nuovo opens an empty window; the clock in the toolbar advances.
- [ ] Drag *PC* and *Switch* from the palette onto the canvas: PC1 and SW1 appear where dropped.
- [ ] Drag from PC1's bottom dot onto SW1: a cable `eth0 ↔ Gi0/1` appears, LEDs turn green.
- [ ] Drag a node: it moves on the 14 pt grid; Cmd+Z puts it back.
- [ ] Pinch to zoom, drag the empty background to pan; right-click ▸ *Adatta alla vista* frames all devices.
- [ ] Right-click empty canvas ▸ *Aggiungi dispositivo* ▸ *Router*: R1 appears under the pointer.
- [ ] Select PC1 ▸ *Interfacce*: type `10.0.0.1/24` + Return; the node shows the IP. Type `10.0.0.999/24`: red error under the field, IP unchanged.
- [ ] While typing in a field, Cmd+Z undoes the typing, not the network.
- [ ] Second PC with `10.0.0.2/24` on the switch; right-click PC1 ▸ *Ping verso* ▸ PC2: output shows four replies.
- [ ] *Tabelle* on PC1 shows the ARP entry; on SW1 the MAC table.
- [ ] Select SW1 and press Delete: switch and cables disappear; Cmd+Z brings all back; Cmd+Shift+Z deletes again.
- [ ] Right-click a cable ▸ *Scollega*.
- [ ] Space pauses/resumes the clock; the speed menu changes it.
- [ ] Cmd+S saves `rete.ptk`; close and reopen it from Finder: same devices, positions, IPs and routes.
- [ ] Open a text file renamed to `.ptk`: macOS shows an error, nothing else opens.
