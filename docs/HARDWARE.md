# HCloud — Production Hardware Purchasing Summary

Hardware to run the **entire** NERC-equivalent stack (ClickHouse, 2× Elasticsearch,
MinIO, RocksDB, Postgres/pgvector, Kuzu, API + workers) concurrently, serve the
public site, and grow. Sized from the real workload: ~7–8 TiB of data and
RAM-/IOPS-hungry databases.

**Two decisive factors:** **RAM** (what blocks the full stack on the 31 GiB dev box)
and **fast NVMe storage** (ClickHouse/ES/RocksDB do heavy random I/O — a spinning HDD
is the bottleneck). ECC memory and drive redundancy are mandatory for a 24/7 server.

---

## Recommended — Dell PowerEdge R760 (2U rack server)

The department-server-room target.

| Component | Spec | Notes |
|---|---|---|
| Chassis | **PowerEdge R760, 2U** + ReadyRails sliding rail kit | fits a standard 19″ rack |
| CPU | **2× Xeon Scalable (Gold), 32–64 cores total** | e.g. 2× Gold 6526Y/6544Y; DBs + API scale with cores |
| RAM | **512 GB DDR5 ECC RDIMM** | 256 GB minimum; scales to multi-TB |
| Boot | **BOSS-N1: 2× 480 GB M.2 NVMe, RAID1** | mirrored OS, separate from data |
| Database storage | **8× 3.84 TB U.2/E3.S NVMe, hot-swap, RAID10** (PERC H965i or ZFS) → ~15 TB usable | ClickHouse/ES/RocksDB/Postgres/Kuzu |
| Bulk / object + backup | **4× 8 TB SAS/SATA** (or external JBOD) | MinIO bulk objects + backup target |
| GPU (optional) | **R760xa** variant → up to 4× NVIDIA (RTX 6000 Ada / L40S) | only if AlphaGenome/ML needs GPU |
| Network | **dual 10/25 GbE** | public serving + redundancy |
| Management | **iDRAC9 Enterprise** | remote KVM/power — essential lights-out |
| Power | **redundant PSU 1+1, 1100–1400 W** | dual PDU feeds |
| Warranty | ProSupport, 5-year | production support |

**Tiers:** *Ideal* 512 GB RAM + 32 TB NVMe raw · *Baseline* 256 GB RAM + 16 TB NVMe raw
(RAID10). Both run the full stack; scale RAM/NVMe for more users and dataset growth.

## Alternatives

- **PowerEdge R660** — 1U, denser/cheaper, fewer drive bays.
- **PowerEdge R760xd2** — many drive bays, if MinIO/datasets grow large.
- **Dell Precision 7960 Tower** — non-rack (deskside): Xeon W, up to 512 GB ECC, same
  NVMe strategy. Choose only if you don't have/ want a rack.

## Why these choices (tied to the workload)

- **512 GB ECC RAM** — realistic concurrent use: ClickHouse ~48 GB, Elasticsearch (2
  nodes) ~32 GB, RocksDB ~16 GB, Postgres/Kuzu/MinIO/API/etc. ~30 GB, **plus OS
  page-cache** for the multi-TB datasets (huge perf win). 256 GB is the floor; the
  31 GiB dev box cannot run the heavy stores together at all.
- **NVMe, not HDD** — ClickHouse/ES/RocksDB random I/O crawls on a ~150 MB/s spinning
  disk and flies on multi-GB/s NVMe. Put the **databases on NVMe**; MinIO's bulk
  objects (2.9 TB) can live on the SAS/SATA/HDD tier.
- **RAID10 / ZFS mirror + backups** — a single un-mirrored disk = single point of data
  loss. Mirror the NVMe tier and keep a backup copy (the existing 22 TB HDD works as a
  backup target).
- **iDRAC + redundant PSU** — operational necessities for a racked, 24/7, lights-out box.

## Server-room checklist

- [ ] 2U rack space (R760) with depth clearance
- [ ] Dual power feeds → PDU → **UPS**
- [ ] Adequate cooling / front-to-back airflow
- [ ] 10/25 GbE uplink to the network
- [ ] iDRAC on the management VLAN for remote ops
- [ ] Backup target for the NVMe data tier (HDD/NAS/offsite)

## One-line order

> **Dell PowerEdge R760** · 2× 16-core Xeon Gold · **512 GB DDR5 ECC** · BOSS-N1
> mirrored boot · **8× 3.84 TB NVMe (RAID10)** · 4× 8 TB SAS for MinIO/backup · dual
> 25 GbE · **iDRAC9 Enterprise** · redundant PSU · 5-yr ProSupport.
