# M7b — manual checks (PVST+, PortFast, STP UI)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Convergenza e stati**
- [ ] SW1 e PC1 su Gi0/1: il cavo mostra subito un pallino ambra all'estremità di SW1; Eventi (filtro STP) elenca `STATO … VLAN 1: disabled → blocking`, `blocking → listening`, dopo 15 s `listening → learning`, dopo 30 s `learning → forwarding`, e il pallino sparisce. Un ping da PC1 prima dei 30 s mostra `drop … [stp-discarding]` su SW1.
- [ ] SW1 ▸ Porte: ogni porta Access ha la casella *PortFast*, spenta; sulle porte Trunk non c'è. Attivala su Gi0/2 e collega PC2: forwarding subito, nessun pallino, nessuna TCN nella lista. Cmd+Z la toglie in un passo.
- [ ] Attiva PortFast su una porta mentre è in listening: passa subito a forwarding.

**Due switch, due cavi**
- [ ] SW1 Gi0/1 — SW2 Gi0/1 e SW1 Gi0/2 — SW2 Gi0/2 (SW1 creato per primo), PC1 su SW1, PC2 su SW2, stessa subnet. Dopo 30 s: pallino rosso all'estremità di SW2 del secondo cavo, nessun avviso di loop; il ping funziona.
- [ ] SW2 ▸ Tabelle: *Spanning Tree VLAN 1* con Gi0/1 root forwarding, Gi0/2 blocked blocking; sotto, `Root 32768/1/… · costo 4 · root port Gi0/1`. SW1: tutte designated, `questo switch è la root`.
- [ ] Eventi, una BPDU di SW1: info `Conf. root = 32768/1/… costo = 0 porta = 0x8001`; PDU *IEEE 802.3 Ethernet* (Lunghezza 50 B), *LLC/SNAP* (OUI 0x00000c, PID 0x010b), *STP* con Root ID, costo, Bridge ID, Port ID, Message age 0 s, Max age 20 s, Hello 2 s, Forward delay 15 s. Il filtro STP nasconde/mostra BPDU e cambi di stato; il colore STP è suo.
- [ ] *Simula guasto* sul primo cavo: Gi0/2 di SW2 passa subito a listening, a forwarding dopo 30 s; il ping riprende. In Eventi una TCN di SW2 e una BPDU di SW1 con `TC TCA`.
- [ ] *Ripristina*: la porta torna in blocking.

**Triangolo e failover indiretto**
- [ ] SW1, SW2, SW3 a triangolo (SW1–SW2, SW1–SW3, SW2–SW3), PC1 su SW1, PC2 su SW2. Dopo la convergenza la porta di SW3 verso SW2 è rossa.
- [ ] *Simula guasto* su SW1–SW2: la porta rossa di SW3 resta in blocking per circa 18 s, poi listening, learning e forwarding: il ping riprende fra 48 e 50 s dopo il guasto.
- [ ] Spegni SW2: i vicini vedono subito la porta giù; riaccendilo: le sue porte ripartono da blocking.

**Priorità e VLAN**
- [ ] Trunk fra SW1 e SW2 su due cavi, access 10 e 20 su entrambi. SW2 ▸ Servizi: *Spanning Tree (PVST+)* con VLAN 1, 10, 20 a 32768. VLAN 20 a 4096: SW2 diventa root della VLAN 20 e in Tabelle la porta bloccata della VLAN 20 è su SW1, quella della VLAN 10 su SW2. Sul cavo il pallino resta rosso a entrambe le estremità del secondo cavo.
- [ ] Le BPDU della VLAN 10 sul trunk sono taggate (802.1Q VLAN ID 10), quelle della VLAN 1 no.
- [ ] Un PC su uno switch con soli trunk in mezzo al loop: la VLAN 10 compare anche nella sua tabella Spanning Tree.

**File e copie**
- [ ] Salva, chiudi e riapri: PortFast e priorità tornano; la rete riconverge da capo (30 s).
- [ ] Apri un progetto M6 o M7a con due switch collegati due volte: si apre, PortFast spento, priorità 32768, nessuna broadcast storm dopo la convergenza.
- [ ] Duplica uno switch: la copia ha le stesse porte e PortFast, priorità 32768.
- [ ] Due hub collegati due volte: l'avviso di loop L2 compare ancora.
