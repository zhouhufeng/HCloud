# Legacy: OpenShift Local (CRC) on a Linux desktop — archived

The first HCloud experiments (2026-07, the `pc` box and an older home desktop) ran
OpenShift Local in a libvirt VM. CRC is a development tool: the VM cost 8–10 GB of the
31 GiB host and delivered a single-node OpenShift that could not be joined or grown. It
was retired for RKE2 on `pc` (see `docs/platforms/linux-baremetal.md`), and the
middleware standardised on K3s.

Kept unchanged for history: `00-prereqs.sh` (libvirt/KVM), `01-install-crc.sh`,
`20-lan-access.sh` (HAProxy to expose the CRC VM on the LAN). The Ubuntu 24.04
`virtiofsd` workaround they needed is recorded in `docs/DEPLOYMENT-STATUS.md`.
Do not start new work here.
