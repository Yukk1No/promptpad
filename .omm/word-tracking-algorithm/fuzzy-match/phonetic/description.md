语音匹配。使用 Double Metaphone 编码比较。处理同音词（right/write/rite → RT）和发音相似但拼写不同的词。源词的 Metaphone 在脚本加载时预计算并缓存（_sourceMetaphones），匹配时只需计算语音转录词的编码。
