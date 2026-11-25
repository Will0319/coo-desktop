Coo · Windows 免安装版 使用说明
================================

1. 把整个 Coo 文件夹解压到任意位置（例如 D:\Coo）。
   注意：不要只把 Coo.exe 单独复制出来，同目录的 dll 和 resources 缺一不可。

2. 双击 Coo.exe 启动。
   屏幕底部会出现鲸鱼娘，任务栏右下角托盘里会出现她的头像。

3. 首次启动会自动打开设置窗口；也可以右键托盘头像 →“设置 API Key…”。
   把 DeepSeek 的 API Key（sk- 开头）粘贴进输入框，点“保存并测试”。
   Key 只保存在本机（Windows DPAPI 加密），不会发送到 DeepSeek 以外的地方。
   Key 申请地址：https://platform.deepseek.com/api_keys

4. 余额每 5 分钟自动刷新一次。点一下鲸鱼、或托盘菜单“查询余额”，可立即刷新。

5. 拖动：按住鲸鱼可以拖到屏幕任意位置；松手后她只在这个高度左右走动。
   右键鲸鱼，或右键托盘头像，可以打开菜单。

6. 托盘菜单里还能：
   - 换配色（DeepSeek / Claude / ChatGPT / Gemini / Kimi / MiniMax / Qwen …）
   - 换服装（女仆装 / 冬装 / 店员装）
   - 调整大小、开关自由活动
   - 开机自启（打包版生效；移动文件夹后需重新勾选一次）
   - 隐藏 / 显示、打开数据文件夹、退出

7. 配置和日志在 %APPDATA%\Coo\ 下（config.json、coo.log）。

注意事项
--------
- 这是未签名的个人构建，Windows SmartScreen 可能提示“未知发布者”：
  点“更多信息”→“仍要运行”即可。
- 仅支持 64 位 Windows；Windows 7 SP1 及以上可运行，推荐 Windows 10/11。
- 余额来自 https://api.deepseek.com/user/balance ，与 DeepSeek 官方一致。
- 角色与动画来自 Coopanion（AGPL-3.0-or-later），
  详见 THIRD-PARTY-NOTICE.md 和 LICENSE-Coopanion.txt。