# NewAPI Lens

`NewAPI Lens` 是一个面向 macOS 的 `new-api` 账户统计面板，用来集中查看余额、消费、模型分布和阶段趋势。

## 功能

- 多账户管理：支持添加、编辑、删除多个 `new-api` 账户
- 总览看板：查看当前余额、今日/本周/本月消耗
- 趋势分析：按天、周、月查看金额或 Token 变化
- 周期报表：汇总周期消费和模型分布
- 菜单栏入口：可从菜单栏快速查看核心数据
- 自动刷新：按设定间隔自动同步账户数据

## 运行环境

- macOS
- Xcode 16 或更新版本

## 使用方式

1. 用 Xcode 打开 `newapi-lens.xcodeproj`
2. 运行应用
3. 在“账户”页添加你的 `new-api` 服务地址、用户 ID 和访问令牌
4. 回到总览、趋势、数据页查看统计结果

## 当前版本

- `v0.6`

## 技术栈

- SwiftUI
- 本地持久化
- `new-api` HTTP API

## 许可证

本项目使用 `GNU Affero General Public License v3.0`，见 `LICENSE`。
