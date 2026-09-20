/// Built-in CLI reference data. These suggestions do not execute the command
/// or claim to inspect server-specific plugins, aliases or resource names.
/// References: https://docs.docker.com/reference/cli/docker/
/// https://docs.docker.com/reference/cli/docker/compose/
/// https://git-scm.com/docs/git
class CommandSpec {
  const CommandSpec(
    this.name,
    this.description, {
    this.arguments = '',
    this.children = const [],
    this.options = const [],
    this.value,
    this.aliases = const [],
  });
  final String name;
  final String description;
  final String arguments;
  final List<CommandSpec> children;
  final List<CommandSpec> options;
  final String? value;
  final List<String> aliases;
  bool matches(String token) => name == token || aliases.contains(token);
}

class ContextCompletion {
  const ContextCompletion(this.spec, this.suffix, this.completed, this.usage);
  final CommandSpec spec;
  final String suffix;
  final String completed;
  final String usage;
}

/// Complete the last token only. Decline shell expressions, open quotes,
/// option values and positional arguments instead of inventing completions.
List<ContextCompletion> completeCommandContext(String input) {
  if (RegExp(r'[\x00-\x1f\x7f$`;|&<>()\\]').hasMatch(input)) return const [];
  final words = <String>[];
  var word = StringBuffer();
  String? quote;
  var quotedLast = false;
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    if (char == quote) {
      quote = null;
    } else if (quote == null && (char == '"' || char == "'")) {
      quote = char;
      quotedLast = true;
    } else if (quote == null && char == ' ') {
      if (word.isNotEmpty) {
        words.add(word.toString());
        word.clear();
      }
      quotedLast = false;
    } else {
      word.write(char);
    }
  }
  if (quote != null || quotedLast) return const [];
  final prefix = word.toString();
  if (words.isEmpty) return const [];
  if (words.first == 'sudo') words.removeAt(0);
  if (words.isEmpty) return const [];
  final rootName = words.removeAt(0);
  CommandSpec? node;
  for (final root in _roots) {
    if (root.matches(rootName)) node = root;
  }
  if (node == null) return const [];
  final path = [rootName];
  var used = <String>{};
  for (var i = 0; i < words.length; i++) {
    final token = words[i];
    if (token == '--') return const [];
    if (token.startsWith('-')) {
      final equal = token.indexOf('=');
      final flag = equal < 0 ? token : token.substring(0, equal);
      CommandSpec? option;
      for (final candidate in [...node!.options, _help]) {
        if (candidate.matches(flag)) option = candidate;
      }
      if (option == null) return const [];
      used.add(option.name);
      if (option.value != null && equal < 0) {
        if (++i >= words.length) return const [];
      } else if (option.value == null && equal >= 0) {
        return const [];
      }
      continue;
    }
    CommandSpec? child;
    for (final candidate in node!.children) {
      if (candidate.matches(token)) child = candidate;
    }
    if (child == null) return const [];
    node = child;
    path.add(token);
    used = {};
  }
  final choices = prefix.startsWith('-') || node!.children.isEmpty
      ? [...node!.options, _help]
      : node.children;
  final base = input.substring(0, input.length - prefix.length);
  final results = <ContextCompletion>[];
  for (final choice in choices) {
    if (used.contains(choice.name)) continue;
    final name = choice.name.startsWith(prefix)
        ? choice.name
        : choice.aliases.where((alias) => alias.startsWith(prefix)).firstOrNull;
    if (name == null || name == prefix) continue;
    final suffix = '${name.substring(prefix.length)} ';
    final arguments = choice.value == null
        ? choice.arguments
        : '<${choice.value}>';
    results.add(
      ContextCompletion(
        choice,
        suffix,
        '$base$name',
        '${path.join(' ')} $name${arguments.isEmpty ? '' : ' $arguments'}',
      ),
    );
  }
  return results;
}

const _help = CommandSpec('--help', '查看此命令的帮助。');
const _detach = CommandSpec('--detach', '在后台运行。', aliases: ['-d']);
const _interactive = CommandSpec('--interactive', '保持标准输入开启。', aliases: ['-i']);
const _tty = CommandSpec('--tty', '分配交互终端。', aliases: ['-t']);
const _follow = CommandSpec('--follow', '持续显示新增日志。', aliases: ['-f']);
const _tail = CommandSpec('--tail', '只显示最后指定行数的日志。', value: '行数');
const _logs = CommandSpec(
  'logs',
  '读取容器日志。',
  arguments: '[选项] <容器>',
  options: [
    _follow,
    _tail,
    CommandSpec('--timestamps', '显示日志时间。', aliases: ['-t']),
    CommandSpec('--since', '显示指定时间之后的日志。', value: '时间'),
  ],
);
const _containers = [
  CommandSpec(
    'attach',
    '连接到运行中容器的输入和输出。',
    arguments: '[选项] <容器>',
    options: [
      CommandSpec('--detach-keys', '指定离开容器终端的按键组合。', value: '按键'),
      CommandSpec('--no-stdin', '不连接标准输入。'),
      CommandSpec('--sig-proxy', '将接收的信号转发给容器进程。'),
    ],
  ),
  CommandSpec('create', '创建容器但不启动。', arguments: '[选项] <镜像>'),
  CommandSpec(
    'exec',
    '在运行中的容器内执行命令。',
    arguments: '[选项] <容器> <命令>',
    options: [
      _detach,
      _interactive,
      _tty,
      CommandSpec('--user', '指定容器内的用户。', aliases: ['-u'], value: '用户'),
      CommandSpec('--workdir', '设置容器内的工作目录。', aliases: ['-w'], value: '目录'),
      CommandSpec('--env', '设置环境变量。', aliases: ['-e'], value: '名称=值'),
    ],
  ),
  _logs,
  CommandSpec('pause', '暂停容器进程。', arguments: '<容器…>'),
  CommandSpec('restart', '重新启动容器。', arguments: '<容器…>'),
  CommandSpec('rm', '删除容器。', arguments: '[选项] <容器…>'),
  CommandSpec(
    'run',
    '从镜像创建并启动容器。',
    arguments: '[选项] <镜像> [命令]',
    options: [
      _detach,
      _interactive,
      _tty,
      CommandSpec('--name', '设置容器名称。', value: '名称'),
      CommandSpec(
        '--publish',
        '映射主机和容器端口。',
        aliases: ['-p'],
        value: '主机端口:容器端口',
      ),
      CommandSpec('--volume', '挂载目录或数据卷。', aliases: ['-v'], value: '源:目标'),
      CommandSpec('--env', '设置环境变量。', aliases: ['-e'], value: '名称=值'),
      CommandSpec('--rm', '退出时自动删除容器。'),
      CommandSpec('--network', '指定容器网络。', value: '网络'),
      CommandSpec('--restart', '设置容器退出后的重启策略。', value: '策略'),
    ],
  ),
  CommandSpec('start', '启动已停止的容器。', arguments: '<容器…>'),
  CommandSpec('stats', '实时查看容器资源用量。', arguments: '[容器…]'),
  CommandSpec('stop', '停止运行中的容器。', arguments: '<容器…>'),
  CommandSpec('top', '查看容器进程。', arguments: '<容器>'),
  CommandSpec('unpause', '恢复已暂停的容器进程。', arguments: '<容器…>'),
  CommandSpec('update', '调整容器配置。', arguments: '[选项] <容器…>'),
  CommandSpec('wait', '等待容器停止并返回退出码。', arguments: '<容器…>'),
];
const _ps = CommandSpec(
  'ps',
  '列出容器。',
  options: [
    CommandSpec('--all', '包括已停止的容器。', aliases: ['-a']),
    CommandSpec('--quiet', '只显示容器 ID。', aliases: ['-q']),
    CommandSpec('--filter', '按条件筛选容器。', aliases: ['-f'], value: '条件'),
    CommandSpec('--format', '设置输出格式。', value: '格式'),
  ],
);
const _compose = CommandSpec(
  'compose',
  '管理多容器应用。',
  aliases: ['docker-compose'],
  options: [
    CommandSpec('--file', '指定 Compose 配置文件。', aliases: ['-f'], value: '文件'),
    CommandSpec('--project-name', '指定项目名称。', aliases: ['-p'], value: '名称'),
  ],
  children: [
    CommandSpec('build', '构建服务镜像。', arguments: '[服务…]'),
    CommandSpec('config', '解析并显示 Compose 配置。'),
    CommandSpec('down', '停止并移除应用容器和网络。'),
    CommandSpec('exec', '在服务容器内执行命令。', arguments: '<服务> <命令>'),
    CommandSpec('images', '查看服务使用的镜像。'),
    CommandSpec(
      'logs',
      '查看服务日志。',
      arguments: '[选项] [服务…]',
      options: [_follow, _tail],
    ),
    CommandSpec('ps', '查看应用容器状态。'),
    CommandSpec('pull', '下载服务镜像。', arguments: '[服务…]'),
    CommandSpec('restart', '重新启动服务。', arguments: '[服务…]'),
    CommandSpec('run', '运行一次性服务命令。', arguments: '<服务> [命令]'),
    CommandSpec('start', '启动现有服务容器。'),
    CommandSpec('stop', '停止服务容器。'),
    CommandSpec(
      'up',
      '创建并启动应用服务。',
      arguments: '[选项] [服务…]',
      options: [
        _detach,
        CommandSpec('--build', '启动前构建镜像。'),
        CommandSpec('--force-recreate', '重新创建容器。'),
        CommandSpec('--remove-orphans', '移除不在当前配置中的服务容器。'),
        CommandSpec('--wait', '等待服务运行或通过健康检查。'),
      ],
    ),
    CommandSpec('version', '查看 Compose 版本。'),
  ],
);
const _roots = [
  CommandSpec(
    'docker',
    '管理容器和镜像。',
    options: [
      CommandSpec('--context', '选择 Docker 上下文。', aliases: ['-c'], value: '名称'),
      CommandSpec('--host', '指定 Docker 服务地址。', aliases: ['-H'], value: '地址'),
    ],
    children: [
      ..._containers,
      _ps,
      _compose,
      CommandSpec(
        'container',
        '管理容器。',
        children: [
          ..._containers,
          _ps,
          CommandSpec('ls', '列出容器。'),
          CommandSpec('inspect', '查看容器详情。'),
        ],
      ),
      CommandSpec(
        'build',
        '根据 Dockerfile 构建镜像。',
        arguments: '[选项] <路径>',
        options: [
          CommandSpec('--tag', '设置镜像名称和标签。', aliases: ['-t'], value: '名称:标签'),
          CommandSpec('--file', '指定 Dockerfile。', aliases: ['-f'], value: '文件'),
          CommandSpec('--no-cache', '构建时不使用缓存。'),
        ],
      ),
      CommandSpec('images', '列出本地镜像。'),
      CommandSpec('inspect', '查看 Docker 对象详情。', arguments: '<对象…>'),
      CommandSpec('info', '查看 Docker 服务信息。'),
      CommandSpec('login', '登录镜像仓库。', arguments: '[仓库]'),
      CommandSpec('logout', '退出镜像仓库登录。', arguments: '[仓库]'),
      CommandSpec('pull', '从仓库下载镜像。', arguments: '<镜像>'),
      CommandSpec('push', '上传镜像到仓库。', arguments: '<镜像>'),
      CommandSpec('tag', '为镜像添加名称或标签。', arguments: '<源镜像> <目标镜像>'),
      CommandSpec('version', '查看客户端和服务端版本。'),
    ],
  ),
  _compose,
  CommandSpec(
    'git',
    '管理 Git 仓库。',
    options: [
      CommandSpec('-C', '在指定目录运行 Git。', value: '目录'),
      CommandSpec('-c', '临时设置配置项。', value: '名称=值'),
    ],
    children: [
      CommandSpec(
        'add',
        '将修改加入暂存区。',
        arguments: '<路径…>',
        options: [
          CommandSpec('--all', '暂存所有修改。', aliases: ['-A']),
          CommandSpec('--patch', '逐块选择需要暂存的修改。', aliases: ['-p']),
        ],
      ),
      CommandSpec('branch', '查看或管理分支。', arguments: '[分支]'),
      CommandSpec('checkout', '切换分支或恢复文件。', arguments: '<分支或路径>'),
      CommandSpec('clone', '克隆远程仓库。', arguments: '<仓库> [目录]'),
      CommandSpec(
        'commit',
        '提交暂存区修改。',
        options: [
          CommandSpec('--message', '填写提交说明。', aliases: ['-m'], value: '说明'),
          CommandSpec('--amend', '修改最近一次提交。'),
        ],
      ),
      CommandSpec(
        'diff',
        '查看修改差异。',
        options: [
          CommandSpec('--staged', '查看已暂存的差异。'),
          CommandSpec('--stat', '显示差异统计。'),
        ],
      ),
      CommandSpec('fetch', '获取远端提交和引用。', arguments: '[远程]'),
      CommandSpec('init', '初始化 Git 仓库。', arguments: '[目录]'),
      CommandSpec(
        'log',
        '查看提交历史。',
        options: [
          CommandSpec('--oneline', '每次提交显示一行。'),
          CommandSpec('--graph', '绘制提交关系图。'),
          CommandSpec('--all', '显示所有引用的历史。'),
        ],
      ),
      CommandSpec('merge', '合并分支历史。', arguments: '<分支>'),
      CommandSpec('pull', '获取并整合远端修改。', arguments: '[远程] [分支]'),
      CommandSpec('push', '将本地提交推送到远端。', arguments: '[远程] [分支]'),
      CommandSpec('rebase', '将提交重新应用到另一基点。', arguments: '[基点]'),
      CommandSpec('restore', '恢复工作区或暂存区文件。', arguments: '<路径…>'),
      CommandSpec(
        'status',
        '查看工作区和暂存区状态。',
        options: [
          CommandSpec('--short', '使用简短状态格式。', aliases: ['-s']),
          CommandSpec('--branch', '显示分支信息。', aliases: ['-b']),
        ],
      ),
      CommandSpec(
        'switch',
        '切换工作分支。',
        arguments: '<分支>',
        options: [
          CommandSpec('--create', '创建并切换到新分支。', aliases: ['-c'], value: '分支'),
        ],
      ),
      CommandSpec('tag', '查看或创建标签。', arguments: '[标签]'),
    ],
  ),
];
