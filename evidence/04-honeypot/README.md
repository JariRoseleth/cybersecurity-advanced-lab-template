# Lab 4 - Cowrie SSH honeypot

Uitgevoerd op: 2026-08-27 21:16:10 +02:00

## Architectuur

- Echte beheers-SSH op `companyrouter`: TCP/2222.
- Aanvaller ziet `192.168.62.253:22` als SSH-honeypot.
- nftables markeert en redirect enkel verkeer naar het eigen routeradres van TCP/22 naar Cowrie TCP/2223.
- Rechtstreeks TCP/2223 blijft door de input-policy geblokkeerd.
- Forwarded SSH naar interne hosts op TCP/22 blijft behouden.
- Cowrie 3.0.13 draait als de niet-root `cowrie`-gebruiker van de officiele image en schrijft persistente logs naar `/opt/cowrie/var`.
- Docker is geconfigureerd met `ip-forward-no-drop`, zodat `net.ipv4.ip_forward=1` en de routerfunctie behouden blijven.

## Isolatie en impact

- `backend = shell` gebruikt de geemuleerde UNIX-shell van Cowrie; er is geen proxy naar een echt backend-systeem geconfigureerd.
- De container draait niet als root, dropt alle Linux-capabilities, heeft een read-only rootfilesystem, `no-new-privileges`, een PID-limiet en een geheugenlimiet.
- Vanaf `red` is alleen de omgeleide TCP/22 bereikbaar. De echte beheerspoort TCP/2222 en Cowrie's private listener TCP/2223 blijven geblokkeerd.
- Commando's worden door Cowrie geemuleerd en gelogd. Downloads, TTY-sessies en auditlogs blijven als bewijs onder `/opt/cowrie/var`; ze worden niet als hostcommando uitgevoerd.
- De test kan daardoor geen echte accounts aanmaken, hostbestanden wijzigen of een echte beheersshell op `companyrouter` verkrijgen.

## Gecontroleerde test

- Mislukte login: `admin` met een fout wachtwoord.
- Geslaagde decoylogin: `root` / `toor`.
- Daarna zijn veilige inventarisatiecommando's uitgevoerd in de geemuleerde Cowrie-shell.
- Vereiste eventtypes: `cowrie.login.failed`, `cowrie.login.success` en `cowrie.command.input`.

## Evidence

- `00-*`: uitgangstoestand en preflight.
- `01-install-companyrouter.txt`: installatie en atomaire omschakeling.
- `02-ssh-client-after.txt`: lokale beheerspoort 2222.
- `03-companyrouter-verification.txt`: services, listeners, firewall en routerfunctie.
- `04-proxyjump-verification.txt`: bereikbaarheid van interne hosts via de bastionhost.
- `04b-ansible-companyrouter-ping.txt`: live Ansible-inventory gebruikt TCP/2222 en krijgt `pong`.
- `05-red-controlled-test.txt`: nmap en gecontroleerde loginpogingen vanaf red.
- `06-cowrie-event-verification.txt`: aantallen per vereist eventtype.
- `07-cowrie-relevant-events.jsonl`: relevante JSON-auditregels.
- `08-final-companyrouter-state.txt`: finale container-, nftables-, poort- en resource-state.

## Rollback

Op `companyrouter`:

```bash
sudo /root/csa-lab4-latest-backup/rollback.sh
```

Herstel daarna lokaal het bestand `C:\Users\jarir\csa-lab4-install-backup-20260827-211537\ssh-config` naar `C:\Users\jarir\.ssh\config` en de overige repositoryback-ups uit `C:\Users\jarir\csa-lab4-install-backup-20260827-211537` wanneer de volledige labwijziging moet worden teruggedraaid.

Herstel ook de live Ansible-inventory:

```powershell
ssh isprouter "cp -a '/home/vagrant/ansible/inventory.yml.csa-lab4-20260827-211537' '/home/vagrant/ansible/inventory.yml'"
```
