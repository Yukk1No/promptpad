# PromptPad

一款语音驱动的自动跟读提词器应用，支持 iOS 和 Android。粘贴稿件，自然说话 —— 应用实时识别语音并自动跟踪朗读位置。

不需要固定滚速，不需要脚踏板，只需要你的声音。

> 临时要上台做 pre，找不到好用的提词器 —— 于是周末用 AI vibe coding 搓了一个。

[**English**](README.md)

<p align="center">
  <img src="assets/screenshots/home.png" alt="PromptPad 主页" width="300">
</p>

## 功能特性

- **语音驱动跟踪** —— 实时语音识别，自动匹配朗读位置并滚动
- **双跟踪算法** —— 经典模式（快速低开销）和高级模式（带波束搜索的漂移恢复）
- **多语言支持** —— 中文、英文、日语、韩语、西班牙语、法语、德语、葡萄牙语等
- **本地识别** —— 支持设备端 ASR 模型，可离线使用
- **镜像模式** —— 水平翻转，适配提词器玻璃/分光镜
- **智能恢复** —— 音素匹配（Double Metaphone）、尾部重锚定、跑偏时自动重新同步
- **Markdown 支持** —— 粘贴 Markdown 稿件，标题变为章节标记，粗体斜体自动清除
- **稿件历史** —— 快速加载最近 5 份稿件
- **屏幕管理** —— 朗读时自动保持屏幕常亮并调至最高亮度

## 快速开始

### 环境要求

- [Flutter](https://docs.flutter.dev/get-started/install) SDK >= 3.2.0
- iOS 15+ 或 Android 5.0+

### 构建与运行

```bash
git clone https://github.com/Yukk1No/promptpad.git
cd promptpad
flutter pub get
flutter run
```

### 发布构建

```bash
flutter build ios        # iOS
flutter build apk        # Android
```

## 使用方法

1. 在主页**粘贴**稿件
2. 点击 **Start** 开始监听
3. **自然朗读** —— 当前词高亮显示，画面自动滚动
4. 使用**左右箭头**跳转句子，**+/-** 调整字号

匹配引擎采用三层流水线：

1. **贪心匹配** —— 从当前位置进行字符级和词级模糊匹配
2. **尾部匹配** —— 取最近几个词在前方窗口中搜索，修正小幅漂移
3. **恢复机制** —— 句子级前向重同步 + 基于锚点词的波束搜索，应对跳读和跑偏

## 设置项

| 设置 | 说明 |
|------|------|
| 语言 / 区域 | 语音识别语言（支持 10 种语言）|
| 跟踪算法 | 经典（V1）或带波束搜索的高级模式（V2）|
| 本地识别 | 使用设备端 ASR 模型，离线可用、速度更快 |
| 默认字号 | 初始显示字号（28–56pt，朗读时可调）|

## 灵感来源

PromptPad 受到两个优秀的开源提词器项目启发：

- [promptme-ai](https://github.com/larsbaunwall/promptme-ai) —— 基于浏览器的语音驱动提词器，使用模糊匹配跟踪稿件位置。PromptPad 的 Double Metaphone 音素匹配方案受其影响。
- [Textream](https://github.com/f/textream) —— 面向主播和播客的 macOS 提词器。PromptPad 的字符级跟踪算法最初移植自 Textream 的实现。

## 许可证

[MIT](LICENSE)
