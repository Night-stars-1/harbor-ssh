# macOS 旧凭证清理

从 1.0.13 开始，Harbor SSH 不再自动迁移或回退读取旧格式凭证。macOS 仅使用服务
`dev.harborssh.credentials` 下、账户为 `harbor.secrets.bundle.v1` 的当前归档。
已在当前归档中的数据仍可读取；只存在于旧逐项记录中的密码、私钥及设置，需要重新录入或导入。
应用不会自动删除旧记录。

## 只删除旧格式记录

1. 完全退出所有 Harbor SSH 实例。确认需要保留的密码、私钥有可用备份。
2. 在 Spotlight 搜索并打开“钥匙串访问”（Keychain Access）。
3. 选择“登录”钥匙串，搜索 `dev.harborssh.credentials`。
4. 双击记录，检查“账户”字段。旧记录的账户包括 `harbor.credentials.*`、
   `harbor.known.*`，以及以前单独保存的 AI、同步设置等。
5. 仅删除服务为 `dev.harborssh.credentials` 的旧记录；保留账户为
   `harbor.secrets.bundle.v1` 的当前归档。不要删除整个“登录”钥匙串。
6. 启动 1.0.13 或更新版本，重新录入缺少的密码、导入私钥，并按需要重新配置同步。

也可以针对已确认的某一条旧记录执行下列命令，将账户参数替换为钥匙串中看到的完整值：

```sh
security delete-generic-password -s 'dev.harborssh.credentials' -a 'harbor.credentials.实际账户ID'
```

## 完全重置 Harbor SSH 安全存储（可选）

如果希望从头配置，或当前归档本身也无法授权，可以在上述步骤中连
`harbor.secrets.bundle.v1` 一并删除。**这会删除当前归档中的密码、私钥、
已信任主机指纹、同步登录信息和 AI 设置，需要重新配置。**

只删除当前归档的命令如下；它不会删除其余旧逐项记录：

```sh
security delete-generic-password -s 'dev.harborssh.credentials' -a 'harbor.secrets.bundle.v1'
```

钥匙串清理不删除偏好设置中的主机列表，也不删除磁盘上的 SSH 密钥文件。
不要通过删除整个 `~/Library/Keychains`、应用容器或 `~/.ssh` 来清理这些记录。
