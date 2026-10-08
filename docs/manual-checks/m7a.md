# M7a — manual checks (VLAN 802.1Q, router-on-a-stick)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Switch ports (Porte)**
- [ ] A new switch: every port shows *Access | Trunk* on Access with VLAN `1`.
- [ ] Gi0/1 VLAN `10` + Return: kept. `0` or `4095`: `VLAN must be between 1 and 4094` under the field; `dieci`: `Invalid number: "dieci"`; Esc puts the value back. No error banner at the top for any of these.
- [ ] Gi0/8 ▸ Trunk: *VLAN ammesse* `all`, *Nativa* `1`. *VLAN ammesse* `10,20`: `Native VLAN 1 is not allowed on the trunk` under it. *Nativa* `10`, then *VLAN ammesse* `10,20`: accepted. `10,abc` and `30-20`: `Invalid VLAN list: …`. Back to Access: VLAN `1` again; back to Trunk: `10,20` and `10` are still there.
- [ ] Each change is one Cmd+Z step.

**Two switches, two VLANs**
- [ ] SW1 Gi0/1 — PC1 (Access 10, 10.0.0.1/24); SW1 Gi0/2 — SW2 Gi0/1, both Trunk; SW2 Gi0/2 — PC2 (Access 10, 10.0.0.2/24); SW2 Gi0/3 — PC3 (Access 20, 10.0.0.3/24). The SW1–SW2 cable reads `Gi0/2 ↔ Gi0/1 · trunk`; the PC cables do not.
- [ ] PC1 ping 10.0.0.2: 4 received. PC1 ping 10.0.0.3: `Destination Host Unreachable`, no reply.
- [ ] Eventi: the echo request on the trunk is 102 B (98 B on the PC cables). Its PDU: *Ethernet II* `EtherType 0x8100 (802.1Q)`, then *802.1Q · 4 B* with `Priorità (PCP) 0`, `DEI 0`, `VLAN ID 10`, `EtherType 0x0800 (IPv4)`.
- [ ] SW2 ▸ Tabelle ▸ Tabella MAC has a VLAN column; PC1's MAC is in VLAN 10 on Gi0/1. Set SW2 Gi0/2 to VLAN 20: the entries on Gi0/2 disappear at once.
- [ ] Give PC3 (VLAN 20) the address 10.0.0.1/24: accepted. Give a PC in VLAN 10 on either switch 10.0.0.1/24: `Duplicate address: 10.0.0.1 is already used by PC1 eth0 on this segment`.
- [ ] Cable a PC4 to a free SW1 port set to Trunk: PC1's broadcasts show `drop … [unknown-vlan]` at PC4.

**Router-on-a-stick**
- [ ] R1 Gi0/0 — SW1 Gi0/8 (Trunk); PC1 on SW1 Access 10, PC2 on SW1 Access 20. R1 ▸ Interfacce ▸ *SOTTOINTERFACCIA 802.1Q*: Gi0/0, VID `10`, `10.0.10.1/24` ▸ *Aggiungi sottointerfaccia*: `Gi0/0.10` appears right under Gi0/0, same MAC, ● collegata, with *Elimina*. Cmd+Z removes it and its address in one step; Cmd+Shift+Z brings both back. Add `20` with `10.0.20.1/24`: listed after `.10`.
- [ ] VID `10` again: `Gi0/0.10 already exists`; `4095`: `VLAN must be between 1 and 4094`; `dieci`: `Invalid number: "dieci"`. A PC, switch or Cloud/ISP has no such form.
- [ ] PC1 10.0.10.10/24 gateway 10.0.10.1, PC2 10.0.20.10/24 gateway 10.0.20.1: PC1 ping 10.0.20.10 gets 4 replies with `ttl=63`. R1 ▸ Tabelle: connected routes and ARP entries on `Gi0/0.10` and `Gi0/0.20`. SW1's MAC table lists R1's MAC in VLAN 10 and in VLAN 20 on Gi0/8.
- [ ] R1 ▸ Servizi: the NAT rows and the firewall interface picker include `Gi0/0.10` and `Gi0/0.20`. Set Gi0/0.10 to *inside*, then *Elimina* on Gi0/0.10: `Gi0/0.10 has a NAT role` under the form, nothing removed. Set it back to —, *Elimina*: gone; PC1's pings to 10.0.10.1 now show `[unknown-vlan]` drops at R1 Gi0/0.
- [ ] R1 ▸ Servizi ▸ Server DHCP for 10.0.20.100–10.0.20.199 (gateway 10.0.20.1), PC2 in DHCP: it gets 10.0.20.100/24.
- [ ] Set SW1 Gi0/8 back to Access: R1's tagged frames show `drop … [vlan-not-allowed]` at SW1 Gi0/8.

**Files and copies**
- [ ] Save the router-on-a-stick lab, close, reopen: port roles and VLANs, subinterfaces and their addresses are back; the ping works again.
- [ ] Open a project saved before M7 (any `.ptk` from M6): every switch port is Access VLAN 1 and the lab works as before.
- [ ] Duplicate the configured switch and router: the copies keep the port VLANs and the subinterfaces, without addresses.
