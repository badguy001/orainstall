# Project uses English only, not Chinese
# Oracle Automated Installation Scripts

Automated installation of **Oracle standalone, ASM standalone, and RAC** deployments for Oracle Database and Grid Infrastructure on multiple Linux distributions.

## Supported Operating Systems

| Family | Distributions |
|--------|---------------|
| Red Hat family | RHEL 6/7/8/9, CentOS, Rocky Linux, Oracle Linux, openEuler, Kylin V10 |
| SUSE family | openSUSE |

## Supported Oracle Versions

| Component | Versions |
|-----------|----------|
| Database | 11gR1, 11gR2, 12cR1, 12cR2, 18c, 19c |
| Grid (ASM/RAC) | 11gR2, 12cR1, 12cR2, 18c, 19c |

## Deployment Types

| ora_type | Description |
|----------|-------------|
| `oracle` | Oracle standalone (file system) |
| `asm` | ASM standalone (Grid + ASM + DB) |
| `rac` | Real Application Clusters |

## Run Modes

| run_mode | Description |
|----------|-------------|
| `env` | Configure environment only (users/groups, kernel params, HugePages, udev, hosts, etc.) |
| `software` | Install GI/DB software only (including patches) |
| `full` | Install software and create database/ASM disk groups |

## Features

- Multi-OS auto-detection and prerequisite package installation
- Silent GI and DB installation (`runInstaller` / `setup.sh`)
- DBCA silent database creation (supports CDB/PDB, RAC, ASM)
- OPatch upgrade (backup, unzip/replace, verify) and patch application (`opatch apply` / `opatch auto`)
- ASM udev rules (supports multipath)
- RAC node SSH trust setup
- NTP slew-mode time synchronization
- ISO mount as yum/dnf repository
- HugePages (80% of memory_for_oracle) + disable Transparent HugePages
- Disable SELinux, firewall, ZEROCONF
- User/group UID/GID starting at 54321
- Simple/detail group modes
- Auto-generated passwords logged to install log

## Quick Start

```bash
chmod +x install_oracle.sh
cp config/oracle.conf.example config/oracle.conf
vi config/oracle.conf
./install_oracle.sh
```

## Configuration Reference

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `ora_type` | `oracle` / `asm` / `rac` |
| `db_version` | DB version |
| `db_install_file` | DB install zip list (comma-separated) |
| `gi_version` | GI version (asm/rac) |
| `gi_install_file` | GI install zip list (asm/rac) |
| `asm_dat_dg` | ASM data disk group (asm standalone) |
| `asm_ocr_dg` | OCR disk group (rac) |
| `ora_net` | Network info (required for rac) |
| `cluster_name` | Cluster name (rac) |
| `root_pwd` | Root password on each node (rac) |

### Common Optional Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `run_mode` | `full` | Run mode |
| `gi_user` | `grid` | GI run user |
| `db_user` | `oracle` | DB run user |
| `gi_pwd` / `db_pwd` | auto-generated | Leave empty to auto-generate |
| `db_home` | `/u01/app/oracle/product/<version>/dbhome_1` | DB home directory |
| `gi_home` | `/u01/app/<version>/grid` | GI home directory |
| `group_mode` | `simple` | `simple` / `detail` |
| `memory_for_oracle` | auto-calculated | Oracle available memory |
| `patch_files` | - | Patch list `file:gi\|db\|gidb` (`gidb` + GI: root `opatch auto` per level-1 subdir; `gidb` without GI: `opatch apply` per level-2 subdir on DB) |
| `opatch_files` | - | OPatch upgrade list `file:gi\|db\|gidb` (GI entries skipped when GI is not installed) |
| `use_multipathd` | `0` | Whether to use multipath |
| `ntp_servers` | - | NTP servers |
| `os_iso_file` | - | OS ISO image |

### ora_net Format

**Standalone / ASM standalone:**
```
hostname:ip
```
IP may be omitted; auto-selection order: default-gateway reachable IP → first private IP → first non-private IP

**RAC:**
```
node1:192.168.1.11:192.168.1.21:10.0.0.11+10.0.0.12,node2:192.168.1.12:192.168.1.22:10.0.0.13+10.0.0.14
```
Format: `hostname:public_ip:vip:priv_ip1+priv_ip2`

### ASM Disk Group Format

```
diskgroup_name:disk_name,WWID,asm_disk_name+disk_name2,WWID2,asm_disk_name2
```

- Multiple disks joined with `+`
- Multiple disk groups separated by `#`
- At least one of `disk_name` or `WWID` is required
- `asm_disk_name` defaults to `disk_name`

Example:
```
asm_ocr_dg="OCR:sdb,3600c0ff0ee...,asm_ocr1+sdc,3600c0ff0ff...,asm_ocr2"
asm_dat_dg="DATA:sdd,3600c0ff0aa...,asm_data1"
```

### memory_for_oracle Auto-Calculation Rules

- Total memory ≤ 100GiB: 80% allocated to Oracle
- Total memory > 100GiB: system reserves 20GiB + 5GiB per 100GiB above 100GiB; remainder goes to Oracle

80% of this value is configured as HugePages; Transparent HugePages are disabled at each boot (without modifying grub).

## Command-Line Options

```bash
./install_oracle.sh -h                      # Help
./install_oracle.sh -c /path/to.conf        # Specify config
./install_oracle.sh --skip-prereqs          # Skip prerequisites
./install_oracle.sh --skip-sysconfig        # Skip system configuration
./install_oracle.sh --verify-only           # Verify installation
./install_oracle.sh --node-env-only         # RAC remote node environment setup
```

## Directory Structure

```
orainstall/
├── install_oracle.sh           # Main entry point
├── config/
│   └── oracle.conf.example     # Configuration template
├── lib/
│   ├── common.sh               # Common functions
│   ├── config.sh               # Config loading and validation
│   ├── os_detect.sh            # OS detection
│   ├── prereqs.sh              # Prerequisites
│   ├── sysconfig.sh            # Kernel/HugePages/SELinux
│   ├── users.sh                # Users and groups
│   ├── network.sh              # hosts configuration
│   ├── udev.sh                 # ASM udev
│   ├── ntp.sh                  # NTP
│   ├── yum_iso.sh              # ISO yum source
│   ├── ssh_setup.sh            # RAC SSH trust
│   ├── gi_install.sh           # Grid installation
│   ├── db_install.sh           # DB installation and database creation
│   └── patch.sh                # Patches
└── README.md
```

## Configuration Examples

### Oracle 19c Standalone

```bash
ora_type="oracle"
db_version="19c"
run_mode="full"
db_install_file="/opt/soft/LINUX.X64_193000_db_home.zip"
ora_net="oradb1:192.168.1.100"
```

### ASM Standalone 19c

```bash
ora_type="asm"
db_version="19c"
gi_version="19c"
run_mode="full"
gi_install_file="/opt/soft/grid.zip"
db_install_file="/opt/soft/db.zip"
asm_dat_dg="DATA:sdc,3600c0ff0abc...,asm_data1+sdd,3600c0ff0def...,asm_data2"
ora_net="oraasm1:192.168.1.101"
```

### RAC 19c (2 nodes)

```bash
ora_type="rac"
db_version="19c"
gi_version="19c"
run_mode="full"
cluster_name="rac19c"
root_pwd="YourRootPassword"
gi_install_file="/opt/soft/grid1.zip,/opt/soft/grid2.zip"
db_install_file="/opt/soft/db1.zip,/opt/soft/db2.zip"
ora_net="rac1:192.168.1.11:192.168.1.21:10.0.0.11+10.0.0.12,rac2:192.168.1.12:192.168.1.22:10.0.0.13+10.0.0.14"
asm_ocr_dg="OCR:sdb,3600c0ff0...,asm_ocr1+sdc,3600c0ff1...,asm_ocr2"
asm_dat_dg="DATA:sdd,3600c0ff2...,asm_data1+sde,3600c0ff3...,asm_data2"
group_mode="detail"
```

## Logs

- Install log: `/var/log/orainstall/install_YYYYMMDD_HHMMSS.log`
- Auto-generated passwords are recorded in the log (`gi_pwd=` / `db_pwd=`)

## Notes

1. Must be run as **root**
2. Install media must be uploaded to the server in advance
3. For RAC, configure network and shared storage on all nodes and run the script from the first node
4. Change default passwords in production; do not commit configs containing passwords to version control
5. Ensure you have a valid Oracle license

## Post-Install Verification

```bash
# Standalone
su - oracle
sqlplus / as sysdba
SQL> select instance_name, status from v$instance;

# RAC
su - grid
crsctl check crs
srvctl status database -d orcl
```

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| Prerequisite package install failed | Check yum/dnf repositories, or configure `os_iso_file` |
| GI/DB install failed | Check `$LOG_FILE` and `oraInventory/logs` |
| ASM disks not visible | Check udev rules and `/dev/asm_*` symlinks |
| RAC SSH trust failed | Verify `root_pwd` and `ora_net` IPs |
| Insufficient HugePages | Adjust `memory_for_oracle` |
