import 'package:flutter/material.dart';

/// 连接可选的图标。id 会保存并同步，只能新增，不能改名或复用。
const hostIconOptions = <({String id, String label, IconData icon})>[
  (id: '', label: '服务器', icon: Icons.dns_rounded),
  (id: 'terminal', label: '终端', icon: Icons.terminal_rounded),
  (id: 'cloud', label: '云主机', icon: Icons.cloud_rounded),
  (id: 'database', label: '数据库', icon: Icons.storage_rounded),
  (id: 'web', label: '网站', icon: Icons.public_rounded),
  (id: 'router', label: '路由器', icon: Icons.router_rounded),
  (id: 'desktop', label: '台式机', icon: Icons.desktop_windows_rounded),
  (id: 'laptop', label: '笔记本', icon: Icons.laptop_rounded),
  (id: 'board', label: '开发板', icon: Icons.developer_board_rounded),
  (id: 'container', label: '容器', icon: Icons.inventory_2_rounded),
  (id: 'security', label: '堡垒机', icon: Icons.shield_rounded),
  (id: 'code', label: '开发', icon: Icons.code_rounded),
  (id: 'build', label: '构建', icon: Icons.build_rounded),
  (id: 'science', label: '测试', icon: Icons.science_rounded),
  (id: 'home', label: '家庭', icon: Icons.home_rounded),
  (id: 'work', label: '公司', icon: Icons.business_rounded),
  (id: 'game', label: '游戏', icon: Icons.sports_esports_rounded),
  (id: 'bolt', label: '高性能', icon: Icons.bolt_rounded),
];

/// `Host.icon` 对应的图标；空值或本版本不认识的 id 显示 [fallback]。
/// 会话传入终端图标，未设置图标时不会和侧栏的「所有连接」混淆。
IconData hostIcon(String id, {IconData? fallback}) =>
    hostIconOptions
        .where((option) => option.id == id && id.isNotEmpty)
        .firstOrNull
        ?.icon ??
    fallback ??
    hostIconOptions.first.icon;

/// 会话的图标：未设置时沿用终端图标。
IconData sessionIcon(String id) =>
    hostIcon(id, fallback: Icons.terminal_rounded);
