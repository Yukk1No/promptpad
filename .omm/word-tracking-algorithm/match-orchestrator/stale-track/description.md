停滞追踪。监测匹配是否在持续推进：
- 有进展：重置 staleCount 为 0
- 无进展但有语音输入：staleCount++
- staleCount 达到阈值 3 时，触发重同步搜索
与 TeleprompterScreen 中的 8 秒超时自动前进配合，提供双重容错。
