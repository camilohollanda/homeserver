# PostgreSQL VM Setup

Cloud-init only preps the OS. PostgreSQL itself is installed by
`bootstrap/postgres/setup.sh`, run from your machine.

> **Duas VMs durante a migração para o PG 18.** A 113 (`.21`, PG 17) é a
> produção; a 118 (`.23`, PG 18) é o destino do upgrade blue/green. Os comandos
> deste README assumem a **118** — rodá-los contra a 113 reinicia o banco de
> produção. Ver `docs/superpowers/specs/2026-08-06-pg18-blue-green-design.md`.

## Architecture

- **OS Disk**: 20GB on SSD (local-lvm) - managed by Terraform
- **Data Disk**: 60GB on SSD (local-lvm) - managed manually in Proxmox for persistence
- **Hostname**: `pg18` na VM 118 (a 113 usa `pg`, acessível como `pg.local` via Avahi)

## Data Disk Setup

The PostgreSQL data directory lives on a separate disk (`/data`) that persists independently of the VM. This allows VM recreation without data loss.

`install.sh` **aborta** se `/data` não for um mountpoint — este passo é
pré-requisito dele, não opcional.

### Create and Attach Data Disk (on Proxmox host)

```bash
# Create 60GB disk on SSD
pvesm alloc local-lvm 118 vm-118-pgdata 60G

# Attach to VM as scsi1
qm set 118 --scsi1 local-lvm:vm-118-pgdata

# Verify
qm config 118 | grep scsi
```

### Format and Mount (on postgres VM)

```bash
# Check disk device name
lsblk

# Format (only if new/empty disk!)
sudo mkfs.ext4 -L pgdata /dev/sdc  # adjust device name as needed

# Create mount point and add to fstab
sudo mkdir -p /data
echo 'LABEL=pgdata /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a

# Verify
df -h /data
```

### Colocar o cluster no disco de dados

**`install.sh` faz isso sozinho** desde 2026-08-06: se
`/data/postgresql/<ver>_main` não existir, ele roda `pg_dropcluster` +
`pg_createcluster -d` naquele caminho. O drop é destrutivo, então há duas
guardas que precisam valer as duas: `/data` tem que ser mountpoint, e o cluster
não pode ter nenhum banco de usuário.

Não há passo manual a executar aqui — basta rodar `setup.sh` com o disco de
dados já montado.

<details>
<summary>Histórico: os passos manuais usados na VM 113 (PG 17)</summary>

Antes de o `install.sh` automatizar isso, a relocação era feita à mão, movendo
um cluster que já existia em vez de recriá-lo. Registrado porque explica por que
o `data_directory` da 113 não é o default do Debian:

```bash
sudo systemctl stop postgresql@17-main

sudo mkdir -p /data/postgresql
sudo chown postgres:postgres /data/postgresql
sudo mv /var/lib/postgresql/17/main /data/postgresql/17_main

sudo sed -i "s|data_directory = '/var/lib/postgresql/17/main'|data_directory = '/data/postgresql/17_main'|" /etc/postgresql/17/main/postgresql.conf

sudo systemctl start postgresql@17-main
sudo -u postgres psql -l
```

Para disco novo/vazio, o caminho era `initdb` direto:

```bash
sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /data/postgresql/17_main
```

Note que esse `initdb` sem flags criava o cluster **sem** data checksums, que
era o default até o PG 17. O `pg_createcluster` do `install.sh` no PG 18 os
deixa ligados.

</details>

## Replacing the Data Disk

If you need to swap the data disk (e.g., moving from HDD to SSD):

### 1. On postgres VM - backup and unmount

```bash
# Backup all databases first!
sudo -u postgres pg_dumpall | gzip > /tmp/pg_backup_$(date +%Y%m%d).sql.gz

# Stop PostgreSQL and unmount
sudo systemctl stop postgresql@18-main
sudo umount /data
```

### 2. On Proxmox host - swap the disk

```bash
# Detach old disk
qm set 118 --delete scsi1

# Remove old disk (adjust storage name)
pvesm free tank-vm:vm-118-pgdata  # or local-lvm:vm-118-pgdata

# Create new disk on desired storage
pvesm alloc local-lvm 118 vm-118-pgdata 60G

# Attach to VM
qm set 118 --scsi1 local-lvm:vm-118-pgdata
```

### 3. On postgres VM - format and restore

```bash
# Check device name
lsblk

# Format new disk
sudo mkfs.ext4 -L pgdata /dev/sdc

# Mount
sudo mount -a

# Recreate the cluster on the fresh disk. Prefer re-running install.sh, which
# does exactly this (pg_dropcluster + pg_createcluster -d) behind its guards:
#   POSTGRES_SSH=deployer@192.168.20.23 ./bootstrap/postgres/setup.sh
# By hand, if you must:
sudo pg_dropcluster --stop 18 main
sudo install -d -m 0755 -o postgres -g postgres /data/postgresql
sudo pg_createcluster 18 main -d /data/postgresql/18_main
sudo systemctl start postgresql@18-main

# Restore from backup
gunzip -c /tmp/pg_backup_*.sql.gz | sudo -u postgres psql
```

## Avahi/mDNS Setup

To make the VM discoverable as `pg.local`:

```bash
sudo apt-get update && sudo apt-get install -y avahi-daemon
sudo hostnamectl set-hostname pg
sudo sed -i 's/127.0.1.1.*/127.0.1.1\tpg/' /etc/hosts
sudo systemctl enable avahi-daemon && sudo systemctl restart avahi-daemon
```

## ⚠️ Rodar `install.sh` derruba as conexões

O script termina com um restart do cluster. Não existe caminho sem isso para
`shared_buffers` e `reserved_connections`, que são de contexto *postmaster*.
Com ~122 conexões seguradas em pools estáticos do Ecto, o restart derruba todas
de uma vez; os pools reconectam sozinhos, mas requisições no meio da janela
erram, e uma liveness probe que falhe pode virar restart de pod. Rode
deliberadamente, não por reflexo.

## Provisioning Databases

Use `pg-provision.sh` to create databases for applications:

```bash
/opt/bootstrap/pg-provision.sh myapp              # Creates myapp_staging DB
/opt/bootstrap/pg-provision.sh myapp --env prod   # Creates myapp_prod DB
```

## Connection budget

This is a **shared instance** — every app DB (werify prod+staging, iddh prod+staging,
infisical, …) lives on the *same* PostgreSQL server and draws from one global
`max_connections` pool. Each app holds its own client-side pool (e.g. werify's
`POOL_SIZE`, plus its Go sidecar stores), so the slots add up fast.

`max_connections = 200` (set in `install.sh`; was the stock 100, which got
exhausted → clients see `FATAL 53300 too_many_connections / remaining connection
slots are reserved for roles with the SUPERUSER attribute`). Changing it requires
a restart — `install.sh` handles that, or `ALTER SYSTEM SET max_connections = N;`
then `sudo systemctl restart postgresql@18-main`. Desde 2026-08-06 o
`install.sh` também roda `ALTER SYSTEM RESET max_connections`, para que o valor
venha do `postgresql.conf` versionado e não de um override que só existe na VM.

**Infisical has priority.** `reserved_connections = 5` (set in `install.sh`) holds
back 5 slots that only members of the predefined `pg_use_reserved_connections` role
may use once the apps have filled the rest. Infisical's role is granted that
membership in `bootstrap/infisical/db-setup.sh`, so a runaway app pool can never
lock Infisical out of its own DB (which would otherwise block *changing* the secret
that caused the runaway). Apps therefore top out at `max_connections − 3 − 5 = 192`.

> **Correção — 2026-08-06.** Até esta data o parágrafo acima descrevia o estado
> *pretendido*, não o real. Uma auditoria do cluster vivo encontrou
> `reserved_connections = 0` e `pg_auth_members` vazio: o `GRANT` de
> `bootstrap/infisical/db-setup.sh:50` nunca chegou a ser executado. A proteção
> estava inerte nas duas pontas, e entre ~jan/2026 e ago/2026 o Infisical não
> teve prioridade nenhuma sobre os apps. O valor e o grant passaram a ser
> aplicados por `install.sh`; entram em vigor na próxima execução dele.
> Conferir os dois lados com:
>
> ```bash
> sudo -u postgres psql -tAc "SHOW reserved_connections;"
> sudo -u postgres psql -tAc "select r.rolname from pg_auth_members m \
>   join pg_roles r on r.oid=m.member join pg_roles g on g.oid=m.roleid \
>   where g.rolname='pg_use_reserved_connections'"
> ```

Budget when adding/scaling an app: **a rolling deploy briefly runs two pods**, so
an app can transiently need `2 × POOL_SIZE` (k8s Deployment `maxSurge`). Keep
`Σ(pool_size) × peak_pods` comfortably under `max_connections − 3` (3 slots are
reserved for superusers).

```bash
# Current usage vs cap, broken down by database
sudo -u postgres psql -c "SHOW max_connections;"
sudo -u postgres psql -c \
  "SELECT datname, usename, count(*) FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC;"
```

## Troubleshooting

```bash
# Check PostgreSQL status
sudo systemctl status postgresql@18-main

# Check logs
sudo journalctl -u postgresql@18-main -f

# Connect to database
sudo -u postgres psql

# List databases
sudo -u postgres psql -l

# Check data directory
sudo -u postgres psql -c "SHOW data_directory;"
```

## Histórico de configuração

Mudanças de configuração deste cluster, com o que motivou cada uma. Entradas
marcadas como **pendente** estão escritas no `install.sh` mas ainda não valem no
cluster vivo — elas entram em vigor na próxima execução do script.

| Data | Mudança | Motivo | Status |
|---|---|---|---|
| 2026-08-06 | `shared_buffers` 128MB → 2GB | VM de 7,7 GB rodando o default de 128MB; os ~925 MB de dados passam a caber inteiros | pendente |
| 2026-08-06 | `random_page_cost` 4 → 1.1 | O default assume disco girando e faz o planner subestimar index scan em SSD | pendente |
| 2026-08-06 | `effective_cache_size` 4GB → 5GB | Refletir a RAM real disponível para cache | pendente |
| 2026-08-06 | `maintenance_work_mem` 64MB → 256MB | VACUUM e criação de índice; poucos concorrentes | pendente |
| 2026-08-06 | `reserved_connections` 0 → 5 | Documentado como ativo desde ~jan/2026, mas o valor era 0 e o `GRANT` nunca rodou — ver a nota de correção acima | pendente |
| 2026-08-06 | `max_connections` migra de `postgresql.auto.conf` para `postgresql.conf` | O valor existia só na VM, fora do git, vindo de um `ALTER SYSTEM` manual | pendente |
| 2026-08-06 | certbot/Let's Encrypt removidos do caminho do Postgres | O cluster é só LAN e servia o cert snakeoil apesar de toda a maquinaria de DNS-01 — o `sed` procurava uma linha comentada que o Debian entrega descomentada | pendente |
| ~2026-01 | `max_connections` 100 → 200 | Pool esgotado em produção: `FATAL 53300 too_many_connections` | aplicado (via `ALTER SYSTEM`, fora do git) |
| ~2025-11 | `data_directory` movido para `/data/postgresql/17_main` | Disco de dados separado, para o banco sobreviver à recriação da VM | aplicado |

