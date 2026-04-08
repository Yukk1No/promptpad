尾部重锚定（Tail-Match Re-Anchoring）。漂移恢复的关键机制。当主匹配因累计误差偏离时，取语音转录的最后 2-5 个词，在当前位置前方 15 词的窗口内搜索最佳连续匹配：
- 提取尾部词并归一化
- 在 [confirmedPosition, confirmedPosition+15] 窗口内滑动搜索
- 使用带缓存 Metaphone 的模糊匹配（_isFuzzyMatchCached）
- 要求至少 2 个连续词匹配
- 跳跃不能超过下一句边界（_nextSentenceCharOffset），防止误跳到后面的句子
