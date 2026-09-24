import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/remote_metrics.dart';

void main() {
  group('远端 Linux 采样解析', () {
    test('登录横幅之外的采样解析出 CPU 计数、内存、根分区与默认网卡流量', () {
      final sample = parseRemoteMetrics('''
Welcome to Ubuntu 24.04 LTS
Last login: Tue Sep 23 10:00:00 2025 from 10.0.0.2
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu   100 0 50 1000 10 0 0 0 200 5
uptime 12345.67
memtotal        16316420 kB
memavail         8000000 kB
swaptotal        2097152 kB
swapfree          1048576 kB
iface eth0
net 1000000 2000000
disks-ok
df /dev/sda1 ext4 10240000 4096000 6144000 40% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.cpuTotal, 1160);
      expect(sample.cpuIdle, 1010);
      expect(sample.uptimeSeconds, 12345.67);
      expect(sample.memoryTotalBytes, 16316420 * 1024);
      expect(sample.swapTotalBytes, 2097152 * 1024);
      expect(sample.swapUsedBytes, 1048576 * 1024);
      expect(sample.memoryUsedBytes, (16316420 - 8000000) * 1024);
      expect(sample.diskTotalBytes, 10240000 * 1024);
      expect(sample.diskUsedBytes, 4096000 * 1024);
      expect(sample.networkRxBytes, 1000000);
      expect(sample.networkTxBytes, 2000000);
    });

    test('哨兵之外的伪造读数被忽略', () {
      final sample = parseRemoteMetrics('''
os Linux
cpu 999999 0 0 0
net 999999999 999999999
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu 10 0 5 100 0 0 0 0
uptime 20.5
memtotal 1000 kB
memavail 400 kB
iface eth0
net 7 8
disks-ok
df /dev/sda1 ext4 1000 400 600 40% /
__HARBOR_REMOTE_METRICS_END__
net 123456789 123456789
''')!;
      expect(sample.cpuTotal, 115);
      expect(sample.cpuIdle, 100);
      expect(sample.memoryUsedBytes, 600 * 1024);
      expect(sample.diskUsedBytes, 400 * 1024);
      expect(sample.networkRxBytes, 7);
      expect(sample.networkTxBytes, 8);
      expect(sample.uptimeSeconds, 20.5);
    });

    test('错误进程输出或哨兵不完整时返回 null', () {
      expect(
        parseRemoteMetrics('Linux version 6.8.0\nMemTotal: 1 kB\n'),
        isNull,
      );
      expect(
        parseRemoteMetrics('__HARBOR_REMOTE_METRICS_END__\nos Linux\n'),
        isNull,
      );
      expect(
        parseRemoteMetrics('__HARBOR_REMOTE_METRICS_BEGIN__\nos Linux\n'),
        isNull,
      );
      expect(parseRemoteMetrics(''), isNull);
    });

    test('非 Linux 主机即使在哨兵内也返回 null', () {
      expect(
        parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Darwin
cpu 1 2 3 4
uptime 9
__HARBOR_REMOTE_METRICS_END__
'''),
        isNull,
      );
      expect(
        parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu 1 2 3 4
__HARBOR_REMOTE_METRICS_END__
''')!.cpuTotal,
        10,
      );
    });

    test('无 /proc 读数时返回 null，部分可用时保留其余字段', () {
      expect(
        parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
__HARBOR_REMOTE_METRICS_END__
'''),
        isNull,
      );
      final cpuOnly = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu 7 0 0 3
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(cpuOnly.cpuTotal, 10);
      expect(cpuOnly.cpuIdle, 3);
      expect(cpuOnly.uptimeSeconds, isNull);
      expect(cpuOnly.memoryTotalBytes, isNull);
      expect(cpuOnly.networkRxBytes, isNull);
      expect(cpuOnly.diskTotalBytes, isNull);
    });

    test('未启用 Swap 与错误空闲值不伪造占用率', () {
      final disabled = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
swaptotal 0 kB
swapfree 0 kB
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(disabled.swapTotalBytes, 0);
      expect(disabled.swapUsedBytes, isNull);
      final invalid = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
swaptotal 100 kB
swapfree 101 kB
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(invalid.swapTotalBytes, 100 * 1024);
      expect(invalid.swapUsedBytes, isNull);
    });

    test('负数、越界总量与非法 df 行按不可用处理', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu 1 -2 3 4
uptime -5
memtotal 100 kB
memavail 200 kB
net 5 -1
disks-ok
df /dev/sda1 ext4 100 200 0 40% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.cpuTotal, isNull);
      expect(sample.uptimeSeconds, isNull);
      expect(sample.memoryUsedBytes, isNull);
      expect(sample.diskTotalBytes, isNull);
      expect(sample.diskUsedBytes, isNull);
      expect(sample.disks, isEmpty);
      expect(sample.networkRxBytes, isNull);
      expect(sample.networkTxBytes, isNull);
    });

    test('缺少默认路由网卡流量时不伪造零值', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu 1 0 1 0
uptime 5
iface eth0
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.cpuTotal, 2);
      expect(sample.networkRxBytes, isNull);
      expect(sample.networkTxBytes, isNull);
    });

    test('无默认网卡时即使收到 net 计数也不可用于计算速率', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
net 100 200
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.networkInterface, isNull);
      expect(sample.networkRxBytes, isNull);
      expect(sample.networkTxBytes, isNull);
    });

    test('每个 CPU 核心按 id 单独解析，聚合行保持原样', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
cpu   160 0 70 1400 14 0 0 0
core cpu0 100 0 50 1000 10 0 0 0
core cpu1 60 0 20 400 4 0 0 0
uptime 10
__HARBOR_REMOTE_METRICS_END__
''')!;
      // 聚合行仍是 /proc/stat 第一行的 user..steal 之和。
      expect(sample.cpuTotal, 1644);
      expect(sample.cpuIdle, 1414);
      expect(sample.cpuCores.keys, ['cpu0', 'cpu1']);
      expect(sample.cpuCores['cpu0']!.total, 1160);
      expect(sample.cpuCores['cpu0']!.idle, 1010);
      expect(sample.cpuCores['cpu1']!.total, 484);
      expect(sample.cpuCores['cpu1']!.idle, 404);
    });

    test('畸形核心行与负计数被丢弃', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
core cpux 1 2 3 4
core cpu0 1 -2 3 4
core cpu1
uptime 5
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.cpuCores, isEmpty);
      expect(sample.uptimeSeconds, 5);
    });

    test('进程按 RSS 取前十，单位为字节且只保留进程名', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
processes-ok
PID RSS COMMAND
process 300 100 alpha
process 301 200 beta
process 302 300 gamma
process 303 400 delta
process 304 500 epsilon
process 305 600 zeta
process 306 700 eta
process 307 800 theta
process 308 900 iota
process 309 1000 kappa
process 310 1100 lambda
process 456 32768 node worker
process 311 50 mu
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.processesAvailable, isTrue);
      expect(sample.processes.map((process) => process.name), [
        'node worker',
        'lambda',
        'kappa',
        'iota',
        'theta',
        'eta',
        'zeta',
        'epsilon',
        'delta',
        'gamma',
      ]);
      expect(sample.processes.first.residentBytes, 32768 * 1024);
      expect(sample.processes.last.residentBytes, 300 * 1024);
      // 名称里的空格是进程名的一部分，不是参数列表。
      final worker = sample.processes.singleWhere(
        (process) => process.pid == 456,
      );
      expect(worker.name, 'node worker');
      expect(worker.residentBytes, 32768 * 1024);
    });

    test('没有成功标记时进程表按不可用处理', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
process 123 65536 postgres
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.processesAvailable, isFalse);
      expect(sample.processes, isEmpty);
    });

    test('畸形进程行被拒绝', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
processes-ok
process abc 100 postgres
process 42 -5 postgres
process 0 100 postgres
process 7 100
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.processesAvailable, isTrue);
      expect(sample.processes, isEmpty);
    });

    test('每个挂载分区单独解析，root 不是第一行也取作聚合值', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df Filesystem Type 1024-blocks Used Available Capacity Mounted on
df /dev/sdb1 ext4 20480000 10240000 9216000 53% /data volume
df /dev/sda1 ext4 10240000 4096000 6144000 40% /
df tmpfs tmpfs 1000 200 800 20% /run/user/1000
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disksAvailable, isTrue);
      // tmpfs 不是存储卷，只留下两个真实分区。
      expect(sample.disks, hasLength(2));
      final data = sample.disks.first;
      expect(data.device, '/dev/sdb1');
      expect(data.fileSystemType, 'ext4');
      expect(data.mountPoint, '/data volume');
      expect(data.totalBytes, 20480000 * 1024);
      expect(data.usedBytes, 10240000 * 1024);
      expect(data.availableBytes, 9216000 * 1024);
      // available 是独立字段：保留块让它不等于 total - used。
      expect(data.usedBytes + data.availableBytes, isNot(data.totalBytes));
      // 百分比取自 df 报表列：used/(used+available)=52.6% 向上取整为 53%。
      expect(data.reportedPercent, 53);
      expect(data.percent, 53);
      expect(sample.disks.last.mountPoint, '/');
      // 聚合值来自 mountPoint == '/' 的行，而不是 df 的第一行。
      expect(sample.diskTotalBytes, 10240000 * 1024);
      expect(sample.diskUsedBytes, 4096000 * 1024);
    });

    test('df 不支持类型列时从 Linux 挂载表补类型并过滤虚拟挂载', () {
      final sample = parseRemoteMetrics(r'''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
mount /dev/vda3 ext4 /
mount tmpfs tmpfs /run
mount /dev/vda2 vfat /boot/efi
mount overlay overlay /var/lib/docker/overlay2/abc/merged
mount /dev/sdb1 ext4 /data\040volume
df-basic Filesystem 1024-blocks Used Available Capacity Mounted on
df-basic /dev/vda3 51200000 41300000 7600000 85% /
df-basic tmpfs 165172 2457 162715 2% /run
df-basic /dev/vda2 201216 6247 194969 4% /boot/efi
df-basic overlay 51200000 41300000 7600000 85% /var/lib/docker/overlay2/abc/merged
df-basic /dev/sdb1 20480000 10240000 9216000 53% /data volume
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks.map((disk) => disk.mountPoint), [
        '/',
        '/boot/efi',
        '/data volume',
      ]);
      expect(sample.disks.map((disk) => disk.fileSystemType), [
        'ext4',
        'vfat',
        'ext4',
      ]);
      expect(RemoteHostMetrics.fromSamples(sample, null).diskPercent, 85);
    });

    test('tmpfs、efivarfs 与容器 overlay 等虚拟挂载不出现在存储卷里', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df Filesystem Type 1024-blocks Used Available Capacity Mounted on
df /dev/nvme0n1p2 ext4 536870912 300000000 236870912 56% /
df /dev/nvme0n1p1 vfat 536576 40000 496576 8% /boot/efi
df /dev/nvme0n1p3 ext4 2199023255552 1000000000 1199023255552 46% /data
df tmpfs tmpfs 8123456 1024 8122432 1% /run
df tmpfs tmpfs 16246912 0 16246912 0% /dev/shm
df devtmpfs devtmpfs 8123456 0 8123456 0% /dev
df efivarfs efivarfs 128 40 88 32% /sys/firmware/efi/efivars
df proc proc 0 0 0 0% /proc
df sysfs sysfs 0 0 0 0% /sys
df cgroup2 cgroup2 0 0 0 0% /sys/fs/cgroup
df overlay overlay 1000000 400000 600000 40% /var/lib/docker/overlay2/abc/merged
df squashfs squashfs 200000 200000 0 100% /snap/core/1234
df /dev/loop0 fuse.snapfuse 200000 200000 0 100% /snap/core22/2411
df rootfs rootfs 1024 1 1023 1% /init
__HARBOR_REMOTE_METRICS_END__
''')!;
      // 截图里十几条虚拟盘只剩 root、EFI 与数据盘三条真实存储。
      expect(sample.disks.map((disk) => disk.mountPoint), [
        '/',
        '/boot/efi',
        '/data',
      ]);
      expect(sample.disks.map((disk) => disk.fileSystemType), [
        'ext4',
        'vfat',
        'ext4',
      ]);
    });

    test('容器根 overlay 保留，非根 overlay 被过滤', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df overlay overlay 50000000 20000000 30000000 40% /
df overlay overlay 50000000 20000000 30000000 40% /etc/hosts
df overlay overlay 50000000 20000000 30000000 40% /var/lib/docker/overlay2/x/merged
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks, hasLength(1));
      expect(sample.disks.single.mountPoint, '/');
      expect(sample.disks.single.fileSystemType, 'overlay');
      expect(sample.diskTotalBytes, 50000000 * 1024);
    });

    test('同一设备的重复挂载只出现一次，root 优先于 bind', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/sda1 ext4 10240000 4096000 6144000 40% /var/lib/docker/volumes/app
df /dev/sda1 ext4 10240000 4096000 6144000 40% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks, hasLength(1));
      expect(sample.disks.single.mountPoint, '/');
      expect(sample.diskUsedBytes, 4096000 * 1024);
    });

    test('NFS、ZFS 与 LVM 卷不会被类型过滤误删，路径空格保留', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/mapper/vg0-root xfs 10000 4000 6000 40% /
df /dev/mapper/vg0-data xfs 20000 5000 15000 25% /srv/data
df tank/vol zfs 5000000 1000000 4000000 20% /tank/vol
df 192.168.1.20:/export/media nfs4 100000 20000 80000 20% /mnt/media archive
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks.map((disk) => disk.fileSystemType), [
        'xfs',
        'xfs',
        'zfs',
        'nfs4',
      ]);
      expect(sample.disks.map((disk) => disk.mountPoint), [
        '/',
        '/srv/data',
        '/tank/vol',
        '/mnt/media archive',
      ]);
      expect(sample.disks.last.device, '192.168.1.20:/export/media');
    });

    test('percent 用 used/(used+available) 向上取整，且优先取报表值', () {
      // total 1000、used 800、available 150：保留块 50。used/total 会算出
      // 80%，df 口径是 800/950 向上取整的 85%。
      const reserved = RemoteDiskUsage(
        device: '/dev/sdg1',
        fileSystemType: 'ext4',
        mountPoint: '/',
        totalBytes: 1000,
        usedBytes: 800,
        availableBytes: 150,
      );
      expect(reserved.percent, 85);
      expect(reserved.percent, isNot(80));

      // 报表里的百分比直接使用，不再重算。
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/sdg1 ext4 1000 800 150 85% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks.single.reportedPercent, 85);
      expect(sample.disks.single.percent, 85);
    });

    test('报表百分比超过 100 时按原值保留，不做截断', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/sdb1 btrfs 1000 950 0 120% /pool
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks.single.reportedPercent, 120);
      expect(sample.disks.single.percent, 120);
    });

    test('零总量、越界、负值与表头行被过滤', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/sdz ext4 0 0 0 0% /empty
df /dev/sdz2 ext4 100 200 0 40% /overused
df /dev/sdy ext4 1000 -1 900 40% /negative
df Filesystem Type 1024-blocks Used Available Capacity Mounted on
df /dev/sda2 vfat 500 100 400 20% /boot
df /dev/sda1 ext4 1000 400 600 40% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disks.map((disk) => disk.mountPoint), ['/boot', '/']);
      expect(sample.disks.map((disk) => disk.fileSystemType), ['vfat', 'ext4']);
      expect(sample.diskTotalBytes, 1000 * 1024);
      expect(sample.diskUsedBytes, 400 * 1024);
    });

    test('没有成功标记时挂载表按不可用处理', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
df /dev/sda1 ext4 10240000 4096000 6144000 40% /
__HARBOR_REMOTE_METRICS_END__
''')!;
      expect(sample.disksAvailable, isFalse);
      expect(sample.disks, isEmpty);
      expect(sample.diskTotalBytes, isNull);
    });
  });

  group('RemoteHostMetrics 采样差值', () {
    const first = RemoteMetricsSample(
      uptimeSeconds: 100,
      cpuTotal: 1000,
      cpuIdle: 800,
      memoryUsedBytes: 50,
      memoryTotalBytes: 200,
      diskUsedBytes: 2,
      diskTotalBytes: 8,
      networkInterface: 'eth0',
      networkRxBytes: 1000,
      networkTxBytes: 2000,
    );
    const second = RemoteMetricsSample(
      uptimeSeconds: 105,
      cpuTotal: 1085,
      cpuIdle: 810,
      memoryUsedBytes: 50,
      memoryTotalBytes: 200,
      diskUsedBytes: 2,
      diskTotalBytes: 8,
      networkInterface: 'eth0',
      networkRxBytes: 1500,
      networkTxBytes: 2250,
    );

    test('第二个样本按计数器差与远端 uptime 差计算 CPU 与网速', () {
      final metrics = RemoteHostMetrics.fromSamples(second, first);
      expect(metrics.cpuPercent, closeTo(75 / 85 * 100, 1e-9));
      expect(metrics.downloadBytesPerSecond, 100);
      expect(metrics.uploadBytesPerSecond, 50);
      expect(metrics.memoryPercent, 25);
      expect(metrics.diskPercent, 25);
      expect(metrics.memoryUsedBytes, 50);
      expect(metrics.memoryTotalBytes, 200);
      expect(metrics.diskUsedBytes, 2);
      expect(metrics.diskTotalBytes, 8);
    });

    test('缺少旧样本时 CPU 与网速为 null，内存与磁盘仍可用', () {
      final metrics = RemoteHostMetrics.fromSamples(first, null);
      expect(metrics.cpuPercent, isNull);
      expect(metrics.downloadBytesPerSecond, isNull);
      expect(metrics.uploadBytesPerSecond, isNull);
      expect(metrics.memoryPercent, 25);
      expect(metrics.diskPercent, 25);
    });

    test('计数器复位时速率与 CPU 为 null，uptime 不前进时速率也为 null', () {
      const rebooted = RemoteMetricsSample(
        uptimeSeconds: 3,
        cpuTotal: 20,
        cpuIdle: 15,
        networkInterface: 'eth0',
        networkRxBytes: 10,
        networkTxBytes: 20,
      );
      final reset = RemoteHostMetrics.fromSamples(rebooted, second);
      expect(reset.cpuPercent, isNull);
      expect(reset.downloadBytesPerSecond, isNull);
      expect(reset.uploadBytesPerSecond, isNull);

      const frozen = RemoteMetricsSample(
        uptimeSeconds: 105,
        cpuTotal: 1100,
        cpuIdle: 820,
        networkInterface: 'eth0',
        networkRxBytes: 1500,
        networkTxBytes: 2250,
      );
      final stalled = RemoteHostMetrics.fromSamples(frozen, second);
      expect(stalled.cpuPercent, closeTo(5 / 15 * 100, 1e-9));
      expect(stalled.downloadBytesPerSecond, isNull);
      expect(stalled.uploadBytesPerSecond, isNull);
    });

    test('默认路由切换网卡时丢弃不兼容的字节差值', () {
      const changed = RemoteMetricsSample(
        networkInterface: 'wlan0',
        uptimeSeconds: 105,
        networkRxBytes: 1500,
        networkTxBytes: 2250,
      );
      final metrics = RemoteHostMetrics.fromSamples(changed, first);
      expect(metrics.downloadBytesPerSecond, isNull);
      expect(metrics.uploadBytesPerSecond, isNull);
    });

    const coreFirst = RemoteMetricsSample(
      uptimeSeconds: 100,
      cpuCores: {
        'cpu0': RemoteCpuTimes(total: 1000, idle: 800),
        'cpu1': RemoteCpuTimes(total: 500, idle: 400),
      },
    );

    test('首份样本没有可比的核心计数，每个核心都为未知', () {
      final metrics = RemoteHostMetrics.fromSamples(coreFirst, null);
      expect(metrics.cpuCores.map((core) => core.id), ['cpu0', 'cpu1']);
      expect(metrics.cpuCores.every((core) => core.percent == null), isTrue);
    });

    test('核心按 id 而不是位置匹配，热插拔与离线核心不沿用计数', () {
      const coreSecond = RemoteMetricsSample(
        uptimeSeconds: 105,
        cpuCores: {
          'cpu2': RemoteCpuTimes(total: 20, idle: 18),
          'cpu0': RemoteCpuTimes(total: 1085, idle: 810),
        },
      );
      final metrics = RemoteHostMetrics.fromSamples(coreSecond, coreFirst);
      // cpu1 本份样本消失，不沿用；cpu2 新出现，没有旧计数；顺序按内核编号。
      expect(metrics.cpuCores.map((core) => core.id), ['cpu0', 'cpu2']);
      expect(metrics.cpuCores.first.percent, closeTo(75 / 85 * 100, 1e-9));
      expect(metrics.cpuCores.last.percent, isNull);
    });

    test('核心计数复位时该核心为未知', () {
      const coreReset = RemoteMetricsSample(
        uptimeSeconds: 3,
        cpuCores: {'cpu0': RemoteCpuTimes(total: 10, idle: 8)},
      );
      final metrics = RemoteHostMetrics.fromSamples(coreReset, coreFirst);
      expect(metrics.cpuCores.single.id, 'cpu0');
      expect(metrics.cpuCores.single.percent, isNull);
    });

    test('核心编号按内核顺序排列，cpu10 排在 cpu2 之后', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
core cpu10 1 0 1 8 0 0 0 0
core cpu2 1 0 1 8 0 0 0 0
core cpu0 1 0 1 8 0 0 0 0
__HARBOR_REMOTE_METRICS_END__
''')!;
      final metrics = RemoteHostMetrics.fromSamples(sample, null);
      expect(metrics.cpuCores.map((core) => core.id), [
        'cpu0',
        'cpu2',
        'cpu10',
      ]);
    });

    test('进程与挂载表随当前样本透传，不随差值改变', () {
      const process = RemoteMemoryProcess(
        pid: 123,
        name: 'postgres',
        residentBytes: 65536 * 1024,
      );
      const disk = RemoteDiskUsage(
        device: '/dev/sda1',
        fileSystemType: 'ext4',
        mountPoint: '/',
        totalBytes: 8,
        usedBytes: 2,
        availableBytes: 5,
      );
      const sample = RemoteMetricsSample(
        uptimeSeconds: 105,
        processes: [process],
        processesAvailable: true,
        disks: [disk],
        disksAvailable: true,
      );
      final metrics = RemoteHostMetrics.fromSamples(sample, second);
      expect(metrics.processes, [process]);
      expect(metrics.processesAvailable, isTrue);
      expect(metrics.disks, [disk]);
      expect(metrics.disksAvailable, isTrue);
      // used/(used+available)=2/7 向上取整为 29%，不是 2/8 的 25%。
      expect(disk.percent, 29);
      expect(metrics.diskPercent, 29);
    });

    test('聚合 diskPercent 取 root 条目的百分比，缺 root 退化为 null', () {
      final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 5
disks-ok
df /dev/sdg1 ext4 1000 800 150 85% /
df /dev/sdb1 ext4 2000 500 1500 25% /data
__HARBOR_REMOTE_METRICS_END__
''')!;
      final metrics = RemoteHostMetrics.fromSamples(sample, null);
      // root 报表是 85%，即便 /data 更靠前也不采用它。
      expect(metrics.diskPercent, 85);

      const noRoot = RemoteMetricsSample(
        uptimeSeconds: 5,
        disksAvailable: true,
        disks: [
          RemoteDiskUsage(
            device: '/dev/sdb1',
            fileSystemType: 'ext4',
            mountPoint: '/data',
            totalBytes: 2000,
            usedBytes: 500,
            availableBytes: 1500,
            reportedPercent: 25,
          ),
        ],
      );
      expect(RemoteHostMetrics.fromSamples(noRoot, null).diskPercent, isNull);
    });
  });
}
