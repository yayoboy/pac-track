# M9a — manual checks (IPv6: indirizzi, NDP, DAD, SLAAC, ICMPv6)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Router e due PC con SLAAC**
- [ ] R1 con PC1 su Gi0/0 e PC2 su Gi0/1 (cavi diretti). R1 ▸ Interfacce: spunta *IPv6* su Gi0/0 e scrivi `2001:db8:1::1/64`; su Gi0/1 `2001:db8:2::1/64`. Compaiono il link-local `fe80::…/64 · link-local` e l'indirizzo `· manuale`, prima `· tentativo` e dopo 1 s senza stato.
- [ ] R1 ▸ Routing: accendi *Routing IPv6 (ipv6 unicast-routing)*. PC1 e PC2 ▸ Interfacce: spunta *IPv6* (SLAAC si spunta da solo). Dopo circa 2 s ogni PC ha `2001:db8:X::…/64 · SLAAC`, con la parte host uguale al link-local (EUI-64 del MAC).
- [ ] Eventi, filtro NDP: le NS di DAD (`NS DAD …` da `::`), la RA di R1 a 1 s (`RA 2001:db8:1::/64, lifetime 1800 s`), la RS dei PC a ff02::2 e la RA di risposta 3 s dopo la prima. Il chip NDP ha il suo colore e i dieci chip stanno su una riga.
- [ ] Tabelle di PC1: *Tabella di routing IPv6* con `C 2001:db8:1::/64` (sotto, `connessa`) su eth0 e `ND ::/0 [2/0]` (sotto, `fe80::…`) su eth0; *Vicini IPv6* con il link-local di R1 e sotto il suo MAC, in `STALE`. Ogni voce sta su due righe e nessuna va a capo. La *Tabella di routing* IPv4 non mostra righe IPv6.
- [ ] App di PC1: ping all'indirizzo SLAAC di PC2 → `PING …(…) 56 data bytes`, 4 risposte `ttl=63`. Traceroute allo stesso indirizzo → `80 byte packets`, hop 1 `2001:db8:1::1`, hop 2 PC2.
- [ ] Dopo il ping la voce di R1 nei *Vicini IPv6* di PC1 passa da `DELAY` a `PROBE` e torna `REACH` (NS unicast e NA negli eventi, circa 5 s dopo); dopo 30 s senza traffico è `STALE`.
- [ ] PDU di una NS: *Ethernet II* EtherType `0x86dd (IPv6)` verso `33:33:ff:…`, *IPv6* con Hop limit 255 e Next header 58, *ICMPv6* con Tipo 135 (Neighbor Solicitation), Target e l'opzione Source link-layer address. Una RA mostra Cur hop limit 64, Router lifetime 1800 s, MTU 1500 e il prefisso con L=1 A=1.

**Errori ICMPv6 e casi limite**
- [ ] Ping da PC1 con TTL 1 → `From 2001:db8:1::1 icmp_seq=1 Time exceeded: Hop limit`; verso `2001:db8:9::1` → `Destination unreachable: No route`; verso `2001:db8:1::99` (nessuno risponde) → tre NS a 1 s di distanza, poi `Address unreachable` e il drop `nd-timeout`; con 1500 byte → `Packet too big: mtu=1500`.
- [ ] Ping verso `fe80::1` o `ff02::1` → l'errore sotto la scheda App.
- [ ] Spegni *Routing IPv6* su R1: un'ultima RA con lifetime 0 e la riga `ND ::/0` sparisce subito dai PC. Riaccendilo: RA subito e la default torna.
- [ ] Aggiungi PC3 su uno switch con PC1 (porte senza PortFast), IPv6 acceso: le RS di 1, 5, 13 e 29 s si perdono nello spanning tree; quella di 61 s passa.
- [ ] Assegna a PC3 a mano l'indirizzo SLAAC di PC1: evento STATO NDP `DAD: … duplicato` e l'indirizzo segnato `· duplicato`.

**Route statiche, dual stack, servizi IPv4**
- [ ] Due router collegati (2001:db8:12::/64) con le reti dei PC dietro: R1 ▸ Routing, route statica `2001:db8:2::/64` via `2001:db8:12::2` (e il ritorno su R2). Il ping fra i PC risponde con ttl=62. Un next hop `fe80::1` dà l'errore sotto il modulo.
- [ ] Con NAT e firewall (policy nega) su R1, il ping IPv4 è bloccato (drop `firewall-default`) e quello IPv6 passa.
- [ ] Router-on-a-stick: IPv6 su `Gi0/0.10`, i frame NDP escono con il tag 10.

**File e copie**
- [ ] Salva, chiudi e riapri: IPv6, indirizzi manuali, SLAAC, *Routing IPv6* e le route statiche IPv6 tornano; DAD, RA e SLAAC ripartono da capo. Un progetto M8b si apre con IPv6 spento ovunque.
- [ ] Duplica R1 e PC1: le copie hanno IPv6 acceso (PC con SLAAC) ma nessun indirizzo manuale e *Routing IPv6* spento. Cmd+Z annulla una modifica IPv6 in un passo.
