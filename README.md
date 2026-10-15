# BatteryScope

macOS 菜单栏电池监控工具。

**只显示实测值。** 凡是只能靠电量计模型推算的数字都不进界面——例如系统"电池健康度"用的是 `NominalChargeCapacity`（模型值），本项目改用 `AppleRawMaxCapacity`（电池实际充到的容量），两者在这台机器上相差约 2.5 个百分点。取舍的理由写在 [docs/ENGINEERING.md](docs/ENGINEERING.md)。

## 特性

**菜单栏**：电量环，充电时转为绿色；点击展开卡片。

**卡片**：秒级供电数据
- 电池功率 / 整机功耗 / 适配器供电——三块取自同一来源（SMC 每秒刷新的寄存器），满足守恒律：适配器 = 整机 + 电池
- 电池电压、电流、温度、风扇转速，附迷你趋势图

**详情窗口**（三个标签页）

| 标签页 | 内容 |
|---|---|
| 总览 | 健康度环、循环环、实测容量 / 设计容量、CPU / GPU 温度、电量计芯片、电芯组 |
| 实时图表 | 12 个实时指标，按 **供电 / 负载 / 温度 / 趋势** 分类 |
| 原始键值 | 完整 IOKit 注册表与 SMC 键值 |

实时图表的时间范围：`5 分钟 · 1 小时 · 本次会话 · 24 小时 · 7 天 · 30 天`。样本在内存保留 6 小时，在磁盘上每分钟一条保留 30 天，超出内存的范围自动读取归档并降采样。

**命令行** `batteryscope-cli`

```
batteryscope-cli                 完整文本报告
batteryscope-cli json            机器可读输出
batteryscope-cli raw             平铺列出全部 IOKit 注册表键值
batteryscope-cli smc             查看 SMC 功率键及其刷新率
batteryscope-cli power           各功率来源同刻对比
batteryscope-cli watch           持续刷新
batteryscope-cli selftest        366 项内置自检
```

## 系统要求

- macOS 14.0 或更高（本项目在 macOS 27 上开发）
- Apple Silicon
- Xcode 命令行工具（Swift 6）

### 构建时的一个 SDK 注意点

`LC_BUILD_VERSION` 的 `sdk` 字段决定控件外观。SwiftPM 默认把部署目标写进 `sdk`（14.0），结果是应用使用旧版控件外观——例如分段控件不是胶囊形、标签栏不在标题栏里。`Package.swift` 因此显式传了链接参数：

```
-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 26.5
```

`Scripts/resolve-sdk.sh` 负责挑选可用的 SDK。

## 构建与安装

```bash
make app     # 编译、运行自检、组装 dist/BatteryScope.app
make dmg     # 生成安装镜像到 ~/Downloads
```

`make app` 会在打包前运行自检，**失败则拒绝打包**，因此 `dist/` 里不会出现半成品。安装即把 `dist/BatteryScope.app` 拖入 `/Applications`。

## 下载与首次打开

从 [Releases](../../releases) 下载 `BatteryScope-<版本>.dmg`。

**要求**：macOS 14.0 或更高、**Apple Silicon（arm64）**。本项目只构建 arm64，Intel Mac 无法运行。

### ⚠️ 关于签名

应用是 **ad-hoc 签名**：`Signature=adhoc`、`TeamIdentifier=not set`，**没有 Developer ID 证书，也没有经过 Apple 公证**。DMG 本身同样未签名（`source=no usable signature`）。

这意味着在**默认安全设置**的 Mac 上，Gatekeeper 会拦截它——你会看到「无法打开，因为 Apple 无法检查其是否包含恶意软件」。这是签名状态的必然结果，不是文件损坏。

首次打开有三种方式，任选其一：

1. **右键点击 App → 打开**，在随后的对话框里再点一次「打开」。只需做一次。
2. **系统设置 → 隐私与安全性**，在底部找到被拦截的提示，点「仍要打开」。
3. **命令行**去掉隔离标记：
   ```bash
   xattr -dr com.apple.quarantine /Applications/BatteryScope.app
   ```

> 开发机上 `spctl -a -t exec` 有时会显示 `accepted`——那说明该机器的 Gatekeeper 被关闭了（`override=security disabled`），**不代表普通用户会遇到的情况**。

### 要做到双击即用

需要：Apple Developer Program 会员 → 申请 **Developer ID Application** 证书 → 用 `--options runtime` 重新签名 → `xcrun notarytool submit --wait` 提交公证 → `xcrun stapler staple` 装订票据。完成这几步后，任何人下载都能直接打开。

## 项目结构

```
Sources/BatteryKit/        数据读取、解析、格式化（无 UI 依赖，可独立测试）
Sources/BatteryScope/      菜单栏应用与界面
Sources/BatteryScopeCLI/   命令行工具与 366 项自检
Scripts/                   打包、SDK 解析、Info.plist 模板
docs/ENGINEERING.md        各数据来源的实测记录与取舍
docs/UI-LOG.md             界面设计与迭代记录
```

## 设计原则

1. **只用实测值**，模型推算值不进界面（文本报告里保留，供诊断）。
2. **一屏之内同一件事只说一次**。
3. **数值必须自洽**：三块功率来自同一来源，用电池时电池功率恰好是整机功耗的相反数——这条守恒律同时也是排查取错寄存器的手段。

## 许可

[MIT](LICENSE)
