该算法接收来自平台语音识别引擎的实时转录文本（iOS: SFSpeechRecognizer, Android: Google Speech Services），需要在部分识别结果（partial）和最终结果（final）两种模式下工作。语音识别天然存在延迟、误识别、口音差异等问题，算法必须容忍这些噪声。脚本在加载时预计算归一化词列表和 Double Metaphone 语音编码，以空间换时间。
