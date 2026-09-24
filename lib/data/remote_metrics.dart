/// A fixed, read-only Linux probe on a separate SSH channel.
///
/// The shell script contains no user input and never runs a discovered
/// executable. Every section is wrapped in explicit sentinels so a login
/// banner or an unexpected process on stdout cannot be mistaken for data.
library;

/// Section sentinels; anything outside these two lines is ignored.
const _beginMarker = '__HARBOR_REMOTE_METRICS_BEGIN__';
const _endMarker = '__HARBOR_REMOTE_METRICS_END__';

/// POSIX-only script. It never contains user input, so it is escaped for its
/// `sh -c '...'` wrapper exactly like [remoteCommandCatalogQuery]: quotes
/// inside the body cannot terminate the wrapper argument early.
const _metricsScript = r'''
LC_ALL=C; export LC_ALL
printf "__HARBOR_REMOTE_METRICS_BEGIN__\n"
printf "os %s\n" "$(uname -s 2>/dev/null)"
if [ -r /proc/stat ]; then
  while IFS= read -r metrics_line; do
    case "$metrics_line" in
      "cpu "*)
        printf "cpu %s\n" "${metrics_line#cpu}"
        ;;
      "cpu"[0-9]*)
        metrics_core=${metrics_line%% *}
        printf "core %s %s\n" "$metrics_core" "${metrics_line#* }"
        ;;
    esac
  done < /proc/stat
fi
if [ -r /proc/uptime ]; then
  metrics_line=
  IFS= read -r metrics_line < /proc/uptime || metrics_line=
  set -- $metrics_line
  if [ -n "${1-}" ]; then printf "uptime %s\n" "$1"; fi
fi
if [ -r /proc/meminfo ]; then
  while IFS= read -r metrics_line; do
    case "$metrics_line" in
      MemTotal:*) printf "memtotal %s\n" "${metrics_line#MemTotal:}" ;;
      MemAvailable:*) printf "memavail %s\n" "${metrics_line#MemAvailable:}" ;;
      SwapTotal:*) printf "swaptotal %s\n" "${metrics_line#SwapTotal:}" ;;
      SwapFree:*) printf "swapfree %s\n" "${metrics_line#SwapFree:}" ;;
    esac
  done < /proc/meminfo
fi
metrics_iface=
if [ -r /proc/net/route ]; then
  while IFS= read -r metrics_line; do
    set -- $metrics_line
    if [ "${2-}" = "00000000" ]; then metrics_iface=${1-}; break; fi
  done < /proc/net/route
fi
if [ -n "$metrics_iface" ]; then
  printf "iface %s\n" "$metrics_iface"
  if [ -r /proc/net/dev ]; then
    while IFS= read -r metrics_line; do
      case "$metrics_line" in
        *:*) ;;
        *) continue ;;
      esac
      metrics_name=${metrics_line%%:*}
      for metrics_token in $metrics_name; do metrics_name=$metrics_token; done
      if [ "$metrics_name" != "$metrics_iface" ]; then continue; fi
      set -- ${metrics_line#*:}
      if [ $# -ge 9 ]; then printf "net %s %s\n" "$1" "$9"; fi
      break
    done < /proc/net/dev
  fi
fi
if command -v ps > /dev/null 2>&1; then
  if metrics_processes=$(ps -eo pid=,rss=,comm= 2>/dev/null); then
    printf "processes-ok\n"
    printf '%s\n' "$metrics_processes" | sort -k2,2nr | head -n 10 | while IFS= read -r metrics_line; do
      if [ -n "$metrics_line" ]; then printf "process %s\n" "$metrics_line"; fi
    done
  fi
fi
if command -v df > /dev/null 2>&1; then
  metrics_disks=$(df -PkT 2>/dev/null)
  set -- $metrics_disks
  if [ "${2-}" = "Type" ]; then
    metrics_disk_mode=typed
  else
    metrics_disks=$(df -Pk 2>/dev/null)
    metrics_disk_mode=basic
  fi
  if [ -n "$metrics_disks" ]; then
    printf "disks-ok\n"
    if [ "$metrics_disk_mode" = basic ] && [ -r /proc/self/mounts ]; then
      while IFS=" " read -r metrics_device metrics_mount metrics_type metrics_rest; do
        printf "mount %s %s %s\n" "$metrics_device" "$metrics_type" "$metrics_mount"
      done < /proc/self/mounts
    fi
    printf '%s\n' "$metrics_disks" | while IFS= read -r metrics_line; do
      if [ -n "$metrics_line" ]; then
        printf "%s %s\n" "df-$metrics_disk_mode" "$metrics_line"
      fi
    done
  fi
fi
printf "__HARBOR_REMOTE_METRICS_END__\n"
''';

/// The exact fixed command sent through SSH exec; no user data is interpolated.
final remoteMetricsQuery = "sh -c '${_metricsScript.replaceAll("'", "'\\''")}'";

/// One core's `/proc/stat` counters, in jiffies.
final class RemoteCpuTimes {
  const RemoteCpuTimes({required this.total, required this.idle});

  /// Sum of the user, nice, system, idle, iowait, irq, softirq and steal
  /// fields.
  final double total;

  /// `idle` + `iowait` from the same line.
  final double idle;
}

/// One CPU core's usage, derived from two samples.
final class RemoteCpuCore {
  const RemoteCpuCore({required this.id, this.percent});

  /// Core id exactly as the kernel printed it, e.g. `cpu0`.
  final String id;

  /// 0..100, or null on the first sample, for a hot-plugged core, and after a
  /// counter reset.
  final double? percent;
}

/// One process from `ps`, reduced to what memory accounting needs.
final class RemoteMemoryProcess {
  const RemoteMemoryProcess({
    required this.pid,
    required this.name,
    required this.residentBytes,
  });

  final int pid;

  /// Executable name (`comm`) only. Arguments and environment, which can carry
  /// secrets, are never collected.
  final String name;

  /// Resident set size in bytes.
  final int residentBytes;
}

/// One mounted filesystem reported by `df -PkT`.
final class RemoteDiskUsage {
  const RemoteDiskUsage({
    required this.device,
    required this.mountPoint,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    this.fileSystemType,
    this.reportedPercent,
  });

  final String device;

  /// Mount point as reported, spaces included.
  final String mountPoint;

  /// Filesystem type exactly as the `df -T` column printed it (`ext4`, `vfat`,
  /// `nfs4`, `overlay`, ...). Null for a volume assembled by hand rather than
  /// parsed from a probe.
  final String? fileSystemType;

  final int totalBytes;
  final int usedBytes;

  /// Space available to unprivileged processes, kept separate from
  /// `total - used` because reserved blocks make the two differ.
  final int availableBytes;

  /// The capacity column `df` printed, kept verbatim instead of recomputed.
  final double? reportedPercent;

  /// Share of the space `df` accounts for that is in use.
  ///
  /// The probe's own percentage wins when it supplied one. Otherwise this is
  /// `used / (used + available) * 100`, rounded up, which is the definition
  /// `df` itself uses: `used / total` would understate usage because reserved
  /// blocks are neither available nor usable.
  double get percent {
    final reported = reportedPercent;
    if (reported != null) return reported;
    final denominator = usedBytes + availableBytes;
    if (denominator <= 0) return 0;
    return (usedBytes / denominator * 100).ceilToDouble();
  }
}

/// One raw reading of the remote host, straight from the kernel counters.
///
/// Values are left in their native units so a later sample can compute rates
/// from the difference; see [RemoteHostMetrics.fromSamples].
final class RemoteMetricsSample {
  const RemoteMetricsSample({
    this.uptimeSeconds,
    this.cpuTotal,
    this.cpuIdle,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
    this.swapUsedBytes,
    this.swapTotalBytes,
    this.diskUsedBytes,
    this.diskTotalBytes,
    this.networkInterface,
    this.networkRxBytes,
    this.networkTxBytes,
    this.cpuCores = const {},
    this.processes = const [],
    this.processesAvailable = false,
    this.disks = const [],
    this.disksAvailable = false,
  });

  /// `/proc/uptime` first field, in seconds. Used as the interval clock so
  /// rates do not depend on the local wall clock.
  final double? uptimeSeconds;

  /// Sum of the `/proc/stat` `cpu` fields (user..steal), in jiffies.
  final double? cpuTotal;

  /// Idle time (`idle` + `iowait`) from the same line, in jiffies.
  final double? cpuIdle;

  final int? memoryUsedBytes;
  final int? memoryTotalBytes;
  final int? swapUsedBytes;
  final int? swapTotalBytes;
  final int? diskUsedBytes;
  final int? diskTotalBytes;

  /// Interface chosen by the remote host's default route at this sample.
  final String? networkInterface;

  /// Receive/transmit bytes of the default-route interface only.
  final int? networkRxBytes;
  final int? networkTxBytes;

  /// Per-core counters keyed by the `/proc/stat` id (`cpu0`, `cpu1`, ...),
  /// every core the host reported. Empty when the host exposed none.
  final Map<String, RemoteCpuTimes> cpuCores;

  /// At most the ten largest resident-memory processes, largest first.
  final List<RemoteMemoryProcess> processes;

  /// True only when the probe confirmed the `ps` listing succeeded. A missing
  /// or failing `ps` leaves this false, so an empty list is never shown as a
  /// reading of zero.
  final bool processesAvailable;

  /// Every usable mounted volume `df -PkT` reported, in probe order: kernel
  /// pseudo filesystems and container layers other than the root are dropped,
  /// and a device mounted several times appears once. Totals are never summed
  /// by callers: mounts overlap and would be counted twice.
  final List<RemoteDiskUsage> disks;

  /// True only when the probe confirmed `df` produced a listing.
  final bool disksAvailable;
}

/// Instantaneous figures derived from one or two [RemoteMetricsSample]s.
final class RemoteHostMetrics {
  const RemoteHostMetrics({
    this.cpuPercent,
    this.memoryPercent,
    this.diskPercent,
    this.downloadBytesPerSecond,
    this.uploadBytesPerSecond,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
    this.swapUsedBytes,
    this.swapTotalBytes,
    this.diskUsedBytes,
    this.diskTotalBytes,
    this.cpuCores = const [],
    this.processes = const [],
    this.processesAvailable = false,
    this.disks = const [],
    this.disksAvailable = false,
  });

  /// CPU, memory and disk usage as a percentage (0..100), or null when the
  /// value cannot be derived without inventing data.
  final double? cpuPercent;
  final double? memoryPercent;
  final double? diskPercent;

  /// Interface throughput, or null on the first sample, after a counter reset,
  /// or when the remote clock did not advance.
  final double? downloadBytesPerSecond;
  final double? uploadBytesPerSecond;

  final int? memoryUsedBytes;
  final int? memoryTotalBytes;
  final int? swapUsedBytes;
  final int? swapTotalBytes;
  final int? diskUsedBytes;
  final int? diskTotalBytes;

  /// Per-core usage, in kernel order. Each entry is null-valued until two
  /// comparable samples exist.
  final List<RemoteCpuCore> cpuCores;

  /// The largest resident-memory processes of the current sample.
  final List<RemoteMemoryProcess> processes;

  /// Whether the probe could read the process table at all.
  final bool processesAvailable;

  /// The mounted filesystems of the current sample.
  final List<RemoteDiskUsage> disks;

  /// Whether the probe could read the mount table at all.
  final bool disksAvailable;

  /// Derive metrics from [current]; [previous] is required for [cpuPercent],
  /// [cpuCores] percentages and the transfer rates, and may be null for the
  /// very first sample.
  factory RemoteHostMetrics.fromSamples(
    RemoteMetricsSample current,
    RemoteMetricsSample? previous,
  ) {
    return RemoteHostMetrics(
      cpuPercent: _cpuUsage(
        current.cpuTotal,
        current.cpuIdle,
        previous?.cpuTotal,
        previous?.cpuIdle,
      ),
      memoryPercent: _percent(
        current.memoryUsedBytes,
        current.memoryTotalBytes,
      ),
      diskPercent: _diskPercent(current),
      downloadBytesPerSecond: _rate(
        current,
        previous,
        (sample) => sample.networkRxBytes,
      ),
      uploadBytesPerSecond: _rate(
        current,
        previous,
        (sample) => sample.networkTxBytes,
      ),
      memoryUsedBytes: current.memoryUsedBytes,
      memoryTotalBytes: current.memoryTotalBytes,
      swapUsedBytes: current.swapUsedBytes,
      swapTotalBytes: current.swapTotalBytes,
      diskUsedBytes: current.diskUsedBytes,
      diskTotalBytes: current.diskTotalBytes,
      cpuCores: _cpuCores(current, previous),
      processes: current.processes,
      processesAvailable: current.processesAvailable,
      disks: current.disks,
      disksAvailable: current.disksAvailable,
    );
  }

  /// One entry per core the **current** sample reported.
  ///
  /// Cores are matched by id, never by position, so a hot-plugged core starts
  /// as null (no previous counters) and a core that vanished is dropped
  /// instead of being carried over. A counter that went backwards (reset) is
  /// null as well.
  static List<RemoteCpuCore> _cpuCores(
    RemoteMetricsSample current,
    RemoteMetricsSample? previous,
  ) {
    final cores = <RemoteCpuCore>[];
    current.cpuCores.forEach((id, times) {
      final before = previous?.cpuCores[id];
      cores.add(
        RemoteCpuCore(
          id: id,
          percent: _cpuUsage(
            times.total,
            times.idle,
            before?.total,
            before?.idle,
          ),
        ),
      );
    });
    cores.sort((left, right) => _compareCoreIds(left.id, right.id));
    return cores;
  }

  /// Kernel order: `cpu0` before `cpu1` before `cpu10`.
  static int _compareCoreIds(String left, String right) {
    final leftIndex = int.tryParse(left.replaceFirst('cpu', ''));
    final rightIndex = int.tryParse(right.replaceFirst('cpu', ''));
    if (leftIndex != null && rightIndex != null) {
      return leftIndex.compareTo(rightIndex);
    }
    return left.compareTo(right);
  }

  /// Busy share of one counter pair; null when the pair is not comparable.
  static double? _cpuUsage(
    double? total,
    double? idle,
    double? previousTotal,
    double? previousIdle,
  ) {
    if (total == null ||
        idle == null ||
        previousTotal == null ||
        previousIdle == null) {
      return null;
    }
    final deltaTotal = total - previousTotal;
    final deltaIdle = idle - previousIdle;
    // A reboot or a smaller counter means the sample pair is not comparable.
    if (deltaTotal <= 0 || deltaIdle < 0 || deltaIdle > deltaTotal) return null;
    return (deltaTotal - deltaIdle) / deltaTotal * 100;
  }

  static double? _percent(int? used, int? total) {
    if (used == null ||
        total == null ||
        total <= 0 ||
        used < 0 ||
        used > total) {
      return null;
    }
    return used / total * 100;
  }

  /// Root mount share, taken from the root row's own percentage.
  ///
  /// The aggregate follows the volume the mount table calls `/`, so a host
  /// whose root has reserved blocks reports what `df` shows rather than a
  /// recomputed `used / total`. Without a root row only the legacy
  /// [RemoteMetricsSample] pair remains, and a sample that carries neither
  /// stays null instead of inventing a number.
  static double? _diskPercent(RemoteMetricsSample sample) {
    for (final disk in sample.disks) {
      if (disk.mountPoint == '/') return disk.percent;
    }
    return _percent(sample.diskUsedBytes, sample.diskTotalBytes);
  }

  static double? _rate(
    RemoteMetricsSample current,
    RemoteMetricsSample? previous,
    int? Function(RemoteMetricsSample sample) pick,
  ) {
    if (current.networkInterface == null ||
        previous?.networkInterface != current.networkInterface) {
      return null;
    }
    final previousTime = previous?.uptimeSeconds;
    final currentTime = current.uptimeSeconds;
    final previousBytes = previous == null ? null : pick(previous);
    final currentBytes = pick(current);
    if (previousTime == null ||
        currentTime == null ||
        previousBytes == null ||
        currentBytes == null) {
      return null;
    }
    final deltaTime = currentTime - previousTime;
    final deltaBytes = currentBytes - previousBytes;
    if (deltaTime <= 0 || deltaBytes < 0) return null;
    return deltaBytes / deltaTime;
  }
}

/// Parse the output of [remoteMetricsQuery].
///
/// Returns null on a non-Linux host, on a probe that failed to report anything
/// usable, or when the sentinels are missing. Nothing outside the sentinels is
/// ever read, so a login banner cannot forge a reading. Rows of a section that
/// never announced itself (`processes-ok`, `disks-ok`) are ignored as well.
RemoteMetricsSample? parseRemoteMetrics(String output) {
  final lines = output.split('\n');
  var start = -1;
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].trim() == _beginMarker) {
      start = index;
      break;
    }
  }
  if (start < 0) return null;
  var end = -1;
  for (var index = start + 1; index < lines.length; index++) {
    if (lines[index].trim() == _endMarker) {
      end = index;
      break;
    }
  }
  if (end < 0) return null;

  String? os;
  double? cpuTotal;
  double? cpuIdle;
  double? uptimeSeconds;
  int? memoryTotalKb;
  int? memoryAvailableKb;
  int? swapTotalKb;
  int? swapFreeKb;
  String? networkInterface;
  int? networkRxBytes;
  int? networkTxBytes;
  final cpuCores = <String, RemoteCpuTimes>{};
  final processes = <RemoteMemoryProcess>[];
  var processesAvailable = false;
  final parsedDisks = <RemoteDiskUsage>[];
  var disksAvailable = false;
  final mountTypes = <String, String>{};

  for (final raw in lines.sublist(start + 1, end)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final separator = _whitespace.firstMatch(line);
    final key = separator == null ? line : line.substring(0, separator.start);
    final value = separator == null ? '' : line.substring(separator.end).trim();
    // The first valid reading of a section wins; later duplicates are ignored.
    switch (key) {
      case 'os':
        os ??= value;
      case 'cpu':
        if (cpuTotal == null) {
          final times = _parseCpuTimes(value);
          cpuTotal = times?.total;
          cpuIdle = times?.idle;
        }
      case 'core':
        final core = _parseCore(value);
        if (core != null && !cpuCores.containsKey(core.$1)) {
          cpuCores[core.$1] = core.$2;
        }
      case 'uptime':
        uptimeSeconds ??= _parseUptime(value);
      case 'memtotal':
        memoryTotalKb ??= _parseKilobytes(value);
      case 'memavail':
        memoryAvailableKb ??= _parseKilobytes(value);
      case 'swaptotal':
        swapTotalKb ??= _parseKilobytes(value);
      case 'swapfree':
        swapFreeKb ??= _parseKilobytes(value);
      case 'iface':
        if (_interfaceName.hasMatch(value)) networkInterface ??= value;
      case 'net':
        if (networkInterface != null && networkRxBytes == null) {
          final parsed = _parseNet(value);
          networkRxBytes = parsed?.$1;
          networkTxBytes = parsed?.$2;
        }
      case 'processes-ok':
        processesAvailable = true;
      case 'process':
        final process = _parseProcess(value);
        if (process != null && processesAvailable) {
          _addTopProcess(processes, process);
        }
      case 'mount':
        final mount = _parseMount(value);
        if (mount != null) mountTypes.putIfAbsent(mount.$1, () => mount.$2);
      case 'disks-ok':
        disksAvailable = true;
      case 'df':
      case 'df-typed':
        if (disksAvailable) {
          final disk = _parseDisk(value);
          if (disk != null) parsedDisks.add(disk);
        }
      case 'df-basic':
        if (disksAvailable) {
          final disk = _parseBasicDisk(value, mountTypes);
          if (disk != null) parsedDisks.add(disk);
        }
    }
  }

  // Keep only the volumes a user can account for: the root mount, real devices
  // and network shares, with repeated mounts of one device collapsed to the
  // root instance or the first occurrence.
  final disks = _selectDisks(parsedDisks);

  // Anything that is not a confirmed Linux host has no /proc contract at all.
  if (os != 'Linux') return null;
  // A Linux host that exposed nothing readable (missing /proc, restricted
  // container) must not look like a live reading of zeroes.
  if (uptimeSeconds == null &&
      cpuTotal == null &&
      cpuCores.isEmpty &&
      memoryTotalKb == null &&
      disks.isEmpty &&
      networkRxBytes == null &&
      networkTxBytes == null) {
    return null;
  }

  final memoryTotalBytes = memoryTotalKb == null ? null : memoryTotalKb * 1024;
  final memoryAvailableBytes = memoryAvailableKb == null
      ? null
      : memoryAvailableKb * 1024;
  final memoryUsedBytes =
      memoryTotalBytes == null ||
          memoryAvailableBytes == null ||
          memoryTotalBytes <= 0 ||
          memoryAvailableBytes < 0 ||
          memoryAvailableBytes > memoryTotalBytes
      ? null
      : memoryTotalBytes - memoryAvailableBytes;
  final swapTotalBytes = swapTotalKb == null ? null : swapTotalKb * 1024;
  final swapFreeBytes = swapFreeKb == null ? null : swapFreeKb * 1024;
  final swapUsedBytes =
      swapTotalBytes == null ||
          swapFreeBytes == null ||
          swapTotalBytes <= 0 ||
          swapFreeBytes < 0 ||
          swapFreeBytes > swapTotalBytes
      ? null
      : swapTotalBytes - swapFreeBytes;

  // The aggregate disk figure is the root filesystem, not whichever row df
  // printed first: the mount table order is not stable across systems.
  RemoteDiskUsage? root;
  for (final disk in disks) {
    if (disk.mountPoint == '/') {
      root = disk;
      break;
    }
  }
  processes.sort((left, right) {
    final byResident = right.residentBytes.compareTo(left.residentBytes);
    return byResident != 0 ? byResident : left.pid.compareTo(right.pid);
  });

  return RemoteMetricsSample(
    uptimeSeconds: uptimeSeconds,
    cpuTotal: cpuTotal,
    cpuIdle: cpuIdle,
    memoryUsedBytes: memoryUsedBytes,
    memoryTotalBytes: memoryTotalBytes,
    swapUsedBytes: swapUsedBytes,
    swapTotalBytes: swapTotalBytes,
    diskUsedBytes: root?.usedBytes,
    diskTotalBytes: root?.totalBytes,
    networkInterface: networkInterface,
    networkRxBytes: networkRxBytes,
    networkTxBytes: networkTxBytes,
    cpuCores: cpuCores,
    processes: processes,
    processesAvailable: processesAvailable,
    disks: disks,
    disksAvailable: disksAvailable,
  );
}

/// Keeps the [_maxProcesses] largest residents without holding the whole table.
void _addTopProcess(
  List<RemoteMemoryProcess> processes,
  RemoteMemoryProcess candidate,
) {
  if (processes.length < _maxProcesses) {
    processes.add(candidate);
    return;
  }
  var smallest = 0;
  for (var index = 1; index < processes.length; index++) {
    if (processes[index].residentBytes < processes[smallest].residentBytes) {
      smallest = index;
    }
  }
  if (candidate.residentBytes > processes[smallest].residentBytes) {
    processes[smallest] = candidate;
  }
}

/// `/proc/stat` counter row: non-negative integer jiffies for user, nice,
/// system, idle, iowait, irq, softirq, steal (guest fields are subsets of
/// user/nice and are therefore excluded once the list exceeds eight fields).
RemoteCpuTimes? _parseCpuTimes(String value) =>
    _parseCpuCounters(_tokens(value), 0);

/// One `core <id> <counters...>` row.
(String, RemoteCpuTimes)? _parseCore(String value) {
  final tokens = _tokens(value);
  if (tokens.length < 2) return null;
  final id = tokens.first;
  if (!_coreId.hasMatch(id)) return null;
  final times = _parseCpuCounters(tokens, 1);
  if (times == null) return null;
  return (id, times);
}

RemoteCpuTimes? _parseCpuCounters(List<String> tokens, int start) {
  if (tokens.length < start + 4) return null;
  final limit = tokens.length > start + 8 ? start + 8 : tokens.length;
  var total = 0.0;
  var idle = 0.0;
  for (var index = start; index < tokens.length; index++) {
    final parsed = int.tryParse(tokens[index]);
    if (parsed == null || parsed < 0) return null;
    if (index >= limit) continue;
    total += parsed;
    if (index == start + 3 || index == start + 4) idle += parsed;
  }
  if (total <= 0) return null;
  return RemoteCpuTimes(total: total, idle: idle);
}

/// `/proc/uptime` first field, in seconds.
double? _parseUptime(String value) {
  final tokens = _tokens(value);
  if (tokens.isEmpty) return null;
  final parsed = double.tryParse(tokens.first);
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return parsed;
}

/// A `<int> kB` value from `/proc/meminfo`, in kibibytes.
int? _parseKilobytes(String value) {
  final tokens = _tokens(value);
  if (tokens.isEmpty) return null;
  final parsed = int.tryParse(tokens.first);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

/// `/proc/net/dev` counters for the default-route interface: rx then tx bytes.
(int, int)? _parseNet(String value) {
  final tokens = _tokens(value);
  if (tokens.length != 2) return null;
  final rx = int.tryParse(tokens[0]);
  final tx = int.tryParse(tokens[1]);
  if (rx == null || tx == null || rx < 0 || tx < 0) return null;
  return (rx, tx);
}

/// One `ps` row: pid, resident set in kibibytes, then the executable name.
///
/// The name keeps its inner spaces; the `ps` header row and malformed counts
/// are rejected.
RemoteMemoryProcess? _parseProcess(String value) {
  final match = _processRow.firstMatch(value);
  if (match == null) return null;
  final pid = int.tryParse(match.group(1)!);
  final residentKb = int.tryParse(match.group(2)!);
  if (pid == null || residentKb == null || pid <= 0 || residentKb < 0) {
    return null;
  }
  return RemoteMemoryProcess(
    pid: pid,
    name: match.group(3)!,
    residentBytes: residentKb * 1024,
  );
}

/// One `df -PkT` row: filesystem, type, 1024-blocks, used, available,
/// capacity, mount point.
///
/// The capacity column must really be a percentage, which rejects the
/// localized header row; the mount point is everything after it, so mount
/// points containing spaces survive. A zero or contradictory total is not a
/// usable capacity reading. The reported percentage is kept as printed, above
/// 100 included: a full or over-committed filesystem is a real reading, not a
/// number to clamp.
RemoteDiskUsage? _parseDisk(String value) {
  final match = _diskRow.firstMatch(value);
  if (match == null) return null;
  return _diskFromFields(
    device: match.group(1)!,
    type: match.group(2)!,
    mountPoint: match.group(7)!,
    total: match.group(3)!,
    used: match.group(4)!,
    available: match.group(5)!,
    percent: match.group(6)!,
  );
}

/// `/proc/self/mounts`: device, mount point and filesystem type. Fields use
/// octal escapes (for example `\\040` for a space).
(String, String)? _parseMount(String value) {
  final match = _mountRow.firstMatch(value);
  if (match == null) return null;
  final mountPoint = _decodeMountField(match.group(3)!);
  if (mountPoint == null) return null;
  return (mountPoint, match.group(2)!);
}

/// Portable `df -Pk` row, with filesystem type joined from `/proc/self/mounts`.
RemoteDiskUsage? _parseBasicDisk(String value, Map<String, String> mountTypes) {
  final match = _basicDiskRow.firstMatch(value);
  if (match == null) return null;
  final mountPoint = _decodeMountField(match.group(6)!);
  final device = _decodeMountField(match.group(1)!);
  if (mountPoint == null || device == null) return null;
  final type = mountTypes[mountPoint];
  // Root remains meaningful in containers even if the mount table is hidden;
  // unknown non-root rows cannot be safely classified as physical storage.
  if (type == null && mountPoint != '/') return null;
  return _diskFromFields(
    device: device,
    type: type,
    mountPoint: mountPoint,
    total: match.group(2)!,
    used: match.group(3)!,
    available: match.group(4)!,
    percent: match.group(5)!,
  );
}

String? _decodeMountField(String value) {
  final decoded = value.replaceAllMapped(_mountEscape, (match) {
    final code = int.parse(match.group(1)!, radix: 8);
    return String.fromCharCode(code);
  });
  return decoded.codeUnits.any((code) => code < 0x20 || code == 0x7f)
      ? null
      : decoded;
}

RemoteDiskUsage? _diskFromFields({
  required String device,
  required String? type,
  required String mountPoint,
  required String total,
  required String used,
  required String available,
  required String percent,
}) {
  final totalKb = int.tryParse(total);
  final usedKb = int.tryParse(used);
  final availableKb = int.tryParse(available);
  final reportedPercent = int.tryParse(percent);
  if (totalKb == null ||
      usedKb == null ||
      availableKb == null ||
      reportedPercent == null ||
      totalKb <= 0 ||
      usedKb < 0 ||
      usedKb > totalKb ||
      availableKb < 0) {
    return null;
  }
  return RemoteDiskUsage(
    device: device,
    fileSystemType: type,
    mountPoint: mountPoint,
    totalBytes: totalKb * 1024,
    usedBytes: usedKb * 1024,
    availableBytes: availableKb * 1024,
    reportedPercent: reportedPercent.toDouble(),
  );
}

/// Drops mounts that hold no user-visible storage and collapses repeats.
///
/// A mount is kept when it is the root mount or its filesystem type is a real
/// volume. Filtering never inspects the device path or the mount point, so an
/// NFS, ZFS or LVM volume survives wherever it is mounted, while a tmpfs or a
/// container layer is dropped wherever it lives. Remaining rows are keyed by
/// (device, type), so binds of one device appear once, with the root instance
/// winning over later binds of the same device.
List<RemoteDiskUsage> _selectDisks(List<RemoteDiskUsage> disks) {
  final kept = <RemoteDiskUsage>[];
  final indexByKey = <String, int>{};
  for (final disk in disks) {
    if (!_isStorageVolume(disk)) continue;
    final key = '${disk.device}\u0000${disk.fileSystemType}';
    final index = indexByKey[key];
    if (index == null) {
      indexByKey[key] = kept.length;
      kept.add(disk);
    } else if (disk.mountPoint == '/' && kept[index].mountPoint != '/') {
      kept[index] = disk;
    }
  }
  return kept;
}

/// Whether a mount is a volume with space a user can account for.
///
/// The root mount is always kept: in a container the root *is* an overlay, and
/// it is still the view of storage that matters. Every other mount of a
/// virtual, container or read-only-image filesystem type is dropped.
bool _isStorageVolume(RemoteDiskUsage disk) {
  if (disk.mountPoint == '/') return true;
  final type = disk.fileSystemType;
  return type == null || !_virtualFileSystemTypes.contains(type);
}

/// Largest resident processes kept per sample.
const _maxProcesses = 10;

/// Filesystem types that describe kernel state, a container layer or a
/// read-only image rather than a volume with space to account for.
const _virtualFileSystemTypes = <String>{
  'tmpfs',
  'devtmpfs',
  'ramfs',
  'rootfs',
  'proc',
  'sysfs',
  'efivarfs',
  'cgroup',
  'cgroup2',
  'overlay',
  'aufs',
  'squashfs',
  'debugfs',
  'tracefs',
  'securityfs',
  'configfs',
  'pstore',
  'mqueue',
  'hugetlbfs',
  'fusectl',
  'autofs',
  'nsfs',
  'bpf',
  'devpts',
  'binfmt_misc',
  'rpc_pipefs',
  'selinuxfs',
  'fuse.gvfsd-fuse',
  'fuse.snapfuse',
};

final _processRow = RegExp(r'^(\d+)\s+(\d+)\s+(\S.*)$');
final _diskRow = RegExp(
  r'^(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S.*)$',
);
final _basicDiskRow = RegExp(
  r'^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S.*)$',
);
final _mountRow = RegExp(r'^(\S+)\s+(\S+)\s+(\S+)$');
final _mountEscape = RegExp(r'\\([0-7]{3})');
final _coreId = RegExp(r'^cpu\d{1,4}$');
final _whitespace = RegExp(r'\s');
final _interfaceName = RegExp(r'^[a-zA-Z0-9_.:@-]{1,64}$');
final _whitespaceRun = RegExp(r'\s+');

List<String> _tokens(String value) =>
    value.split(_whitespaceRun).where((token) => token.isNotEmpty).toList();
