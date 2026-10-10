# M8a — manual checks (RIPv2, route types)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Due router**
- [ ] R1 e R2 collegati (Gi0/1–Gi0/1, 10.0.12.1/30 e 10.0.12.2/30), PC1 su R1 Gi0/0 (192.168.1.0/24), PC2 su R2 Gi0/0 (192.168.2.0/24), gateway sui PC. R1 ▸ Servizi: *RIP v2* spento ("Spento."). Accendilo: Gi0/0 e Gi0/1 *attiva*, Gi0/2 e Gi0/3 *—*. Stesso su R2.
- [ ] Subito dopo: R1 ▸ Tabelle mostra `R 192.168.2.0/24 [120/1] 10.0.12.2 Gi0/1`, le connesse con tipo `C` e colonna AD/m vuota. Un ping da PC1 a PC2 risponde con ttl=62.
- [ ] Eventi, filtro RIP: R1 manda una Request (`10.0.12.1 → 224.0.0.9 RIPv2 Request`) e una Response; R2 risponde in unicast a 10.0.12.1; ogni 30 s un update periodico. Il colore RIP è suo, i pacchetti sul canvas hanno lo stesso colore.
- [ ] PDU di un update: *Ethernet II* (destinazione 01:00:5e:00:00:09), *IPv4* TTL 1, *UDP* 520 → 520, *RIPv2* con Comando 2 (Response), Versione 2 e una voce per route (maschera, next hop 0.0.0.0, metrica, tag 0).
- [ ] Split horizon: gli update di R1 su Gi0/1 contengono solo 192.168.1.0/24, mai 10.0.12.0/30 né le reti apprese da R2.
- [ ] Rendi passiva Gi0/0 su R1: PC1 non riceve più update RIP; R2 continua a imparare 192.168.1.0/24. Mettila a *—*: dopo 180 s R2 la perde (update con metrica 16 nella lista), dopo altri 120 s sparisce anche dagli update.
- [ ] Una rotta statica su R1 per 192.168.2.0/24 via 10.0.12.2: in Tabelle compare `S … [1/0]` e la riga `R` sparisce; togliendola la `R` torna.

**Triangolo e guasti**
- [ ] R3 collegato a R1 (Gi0/2, 10.0.13.0/30) e a R2 (Gi0/2, 10.0.23.0/30), RIP su tutti e tre, LAN passive. *Simula guasto* su R1–R2 subito dopo un update periodico: R1 perde subito 192.168.2.0/24 e manda un triggered update con metrica 16; al successivo update periodico di R3 (entro 30 s) R1 mostra `R 192.168.2.0/24 [120/2] via 10.0.13.2` e il ping riprende con ttl=61. *Ripristina*: R1 torna su `[120/1]` via R2 al prossimo update di R2.
- [ ] Spegni R2: R1 e R3 tolgono subito le route via R2. Riaccendilo: R2 manda subito una Request e in pochi istanti ha di nuovo tutte le route.
- [ ] Firewall su R1 con policy *nega*: nessuna route RIP, drop `firewall-default` sugli update. Una regola *consenti udp porta 520 in* su Gi0/1: al prossimo update R1 impara di nuovo.

**Sottointerfacce, errori, file**
- [ ] Router-on-a-stick con Gi0/0.10: la sottointerfaccia compare in *RIP v2* e partecipa; gli update escono con 802.1Q VLAN ID 10. Eliminarla mentre è attiva in RIP dà l'errore "Gi0/0.10 takes part in RIP".
- [ ] Rendi passiva un'interfaccia: Cmd+Z la riporta attiva in un passo.
- [ ] Salva, chiudi e riapri: RIP e i ruoli delle interfacce tornano, le route si reimparano da capo. Un progetto M7 si apre con RIP spento. Duplica un router con RIP: la copia ha RIP spento.
