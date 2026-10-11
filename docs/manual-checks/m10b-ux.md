# M10b — manual checks (porte collegate e suggerimenti IP, dalla v1)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Collegata a**
- [ ] SW1 con PC1 su Gi0/1: nella scheda *Porte* di SW1, Gi0/1 mostra `● PC1 eth0` in verde; le porte senza cavo `○ libera`. Nella scheda *Interfacce* di PC1, eth0 mostra `● SW1 Gi0/1`.
- [ ] Router-on-a-stick: le sottointerfacce `Gi0/0.10` mostrano il dispositivo all'altro capo della fisica, con *Elimina* sulla stessa riga.
- [ ] Rinomina PC1 con un nome lungo (`Stampante-ufficio-secondo-piano`): nella scheda *Porte* di SW1 la riga di Gi0/1 resta una sola, il nome si accorcia al centro e la porta resta leggibile; il nome dell'interfaccia non si accorcia.
- [ ] Scollega il cavo o Cmd+Z: la riga torna `○ libera`. Rinomina il dispositivo all'altro capo: il nuovo nome compare subito.

**Suggerimenti IP**
- [ ] SW1 con R1 Gi0/0 `192.168.1.1/24`, PC1 `192.168.1.10/24` e PC2 senza indirizzo. Clic su *Indirizzo IPv4 / prefisso* di PC2: sotto il campo compaiono al massimo tre suggerimenti, `192.168.1.2/24`, `192.168.1.3/24`, `192.168.1.4/24`.
- [ ] Digitando `192.168.1.` restano solo quelli che iniziano così; scegliendone uno il campo si riempie, Invio lo applica, Esc lo annulla (con il menu aperto il primo Esc chiude solo il menu).
- [ ] Scelto col mouse, il suggerimento riempie il campo intero: non viene mai applicato il testo parziale (`192.168.1.`). Un campo che ha già un indirizzo non mostra suggerimenti finché non lo cancelli.
- [ ] Con un Server DHCP sullo switch (pool `.100`–`.199`) i suggerimenti saltano anche il server e il pool.
- [ ] Campo *Gateway predefinito* di PC2 (scheda *Routing*): suggerisce `192.168.1.1` (R1); un Cloud/ISP sullo stesso segmento compare anch'esso, PC e server mai.
- [ ] Gli switch in VLAN diverse separano i suggerimenti: un PC in VLAN 20 non vede indirizzi della VLAN 10. Dietro un router, un'altra rete.
- [ ] Un PC su uno switch senza indirizzi, o senza cavo, non mostra suggerimenti. Il campo IPv6 non ne mostra.
